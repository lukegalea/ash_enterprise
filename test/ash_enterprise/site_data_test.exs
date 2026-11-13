defmodule AshEnterprise.SiteDataTest do
  @moduledoc """
  Keeps the data the public site renders honest against the code it describes.

    * `docs/packages.json` lists every first-party package, fork and override the
      build resolves, with the commit mix.lock pins, how mix.exs declares it,
      whether the battery exercises it, and a maturity the tree bears out.
    * `docs/routes.json` is what `AshEnterpriseWeb.Router` compiles in this
      environment (`mix ash_enterprise.site_routes` writes it).
    * `docs/failures.json` names the tour's failures and the beats that show
      them as `AshEnterpriseWeb.ShowcaseLive.TourIndex` does.

  The site's own checks (shape, snippets, links) are in
  `site/scripts/site-data.test.mjs`, which the site job runs.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp read_json!(relative), do: @root |> Path.join(relative) |> File.read!() |> Jason.decode!()

  defp mentions?(contents, module) do
    pattern = Regex.compile!("(?<![A-Za-z0-9_.])" <> Regex.escape(module) <> "(?![A-Za-z0-9_])")
    Enum.any?(contents, &Regex.match?(pattern, &1))
  end

  defp sources(globs) do
    globs
    |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1)))
    |> Enum.map(&File.read!/1)
  end

  setup_all do
    lock = Mix.Dep.Lock.read(Path.join(@root, "mix.lock"))
    data = read_json!("docs/packages.json")

    ours =
      for {name, {:git, "https://github.com/lukegalea/" <> _, sha, _opts}} <- lock,
          into: %{},
          do: {Atom.to_string(name), sha}

    declared =
      for dep <- Mix.Project.config()[:deps], into: %{} do
        opts =
          if is_list(elem(dep, tuple_size(dep) - 1)), do: elem(dep, tuple_size(dep) - 1), else: []

        {Atom.to_string(elem(dep, 0)), opts}
      end

    battery =
      Regex.scan(~r/\{:(\w+),/, File.read!(Path.join(@root, "battery/mix.exs")),
        capture: :all_but_first
      )
      |> List.flatten()
      |> MapSet.new()

    %{
      packages: data["packages"],
      forks: data["forks"],
      overrides: data["overrides"],
      ours: ours,
      declared: declared,
      battery: battery,
      lib_sources: sources(["lib/**/*.ex", "lib/**/*.exs", "lib/**/*.heex"]),
      test_sources: sources(["test/**/*.ex", "test/**/*.exs"])
    }
  end

  describe "docs/packages.json" do
    test "lists every first-party package the build resolves, and nothing else", ctx do
      fork_names = MapSet.new(ctx.forks, & &1["name"])

      expected =
        (Map.keys(ctx.ours) |> Enum.reject(&MapSet.member?(fork_names, &1))) ++
          for({name, opts} <- ctx.declared, Keyword.has_key?(opts, :path), do: name)

      listed = Enum.map(ctx.packages, & &1["name"])

      assert listed -- Enum.uniq(listed) == [], "a package is listed twice"

      assert Enum.sort(listed) == Enum.sort(expected), """
      docs/packages.json disagrees with mix.lock and mix.exs.
        missing from the file: #{inspect(Enum.sort(expected -- listed))}
        listed but not resolved: #{inspect(Enum.sort(listed -- expected))}
      """
    end

    test "each package's ref is the commit mix.lock pins", ctx do
      wrong =
        for %{"name" => name, "ref" => ref} <- ctx.packages,
            Map.has_key?(ctx.ours, name),
            ref != ctx.ours[name],
            do: "#{name}: file #{ref}, mix.lock #{ctx.ours[name]}"

      assert wrong == [], """
      Refs out of date. Re-read each row's version and stated_status at the new commit, then set ref:
      #{Enum.join(wrong, "\n")}
      """
    end

    test "each package is declared the way the file says", ctx do
      wrong =
        Enum.reject(ctx.packages, fn package ->
          opts = ctx.declared[package["name"]]

          declared =
            cond do
              is_nil(opts) -> "transitive"
              Keyword.has_key?(opts, :path) -> "path"
              true -> "direct"
            end

          only =
            opts |> List.wrap() |> Keyword.get(:only) |> List.wrap() |> Enum.map(&to_string/1)

          package["declared"] == declared and List.wrap(package["only"]) == only and
            (package["declared"] == "path" or is_binary(package["ref"]))
        end)

      assert wrong == [],
             "declared/only/ref wrong for: #{Enum.map_join(wrong, ", ", & &1["name"])}"
    end

    test "the battery flag matches battery/mix.exs", ctx do
      wrong =
        Enum.reject(ctx.packages, &(&1["battery"] == MapSet.member?(ctx.battery, &1["name"])))

      assert wrong == [], "battery flag wrong for: #{Enum.map_join(wrong, ", ", & &1["name"])}"
    end

    test "each maturity is what lib/ and test/ show", ctx do
      wrong =
        Enum.reject(ctx.packages, fn %{"module" => module} = package ->
          only = ctx.declared[package["name"]] |> List.wrap() |> Keyword.get(:only)

          case package["maturity"] do
            "used-and-tested-here" ->
              is_nil(only) and mentions?(ctx.lib_sources, module) and
                mentions?(ctx.test_sources, module)

            "wired-not-tested-here" ->
              is_nil(only) and mentions?(ctx.lib_sources, module) and
                not mentions?(ctx.test_sources, module)

            "tooling" ->
              only != nil and not Enum.member?(List.wrap(only), :prod)

            _unknown ->
              false
          end
        end)

      assert wrong == [],
             "maturity does not match the tree for: #{Enum.map_join(wrong, ", ", & &1["name"])}"
    end

    test "every package says what it is, how it ships and what carrying it means", ctx do
      fields = ~w(name module repo purpose used_for maturity distribution hex_name hex_path carry)

      incomplete =
        for package <- ctx.packages,
            field <- fields,
            not (is_binary(package[field]) and String.trim(package[field]) != ""),
            do: "#{package["name"]}.#{field}"

      assert incomplete == []
      assert Enum.all?(ctx.packages, &String.starts_with?(&1["distribution"], "git only"))
      assert Enum.all?(ctx.packages, &is_list(&1["builds_on"]))
    end

    test "each fork is a pinned git dependency, at the commit mix.lock pins", ctx do
      wrong =
        for fork <- ctx.forks,
            ctx.ours[fork["name"]] != fork["ref"],
            do:
              "#{fork["name"]}: file #{fork["ref"]}, mix.lock #{inspect(ctx.ours[fork["name"]])}"

      assert wrong == [], Enum.join(wrong, "\n")
    end

    test "every override in mix.exs is a listed package, fork or override", ctx do
      overridden = for {name, opts} <- ctx.declared, Keyword.get(opts, :override, false), do: name

      listed =
        Enum.map(ctx.packages ++ ctx.forks ++ ctx.overrides, & &1["name"]) |> MapSet.new()

      assert Enum.reject(overridden, &MapSet.member?(listed, &1)) == []

      hex_overrides = Enum.reject(overridden, &Map.has_key?(ctx.ours, &1))
      assert Enum.sort(hex_overrides) == Enum.sort(Enum.map(ctx.overrides, & &1["name"]))
    end
  end

  describe "docs/routes.json" do
    test "is what the router compiles; run `mix ash_enterprise.site_routes` after changing a route" do
      file = File.read!(Path.join(@root, Mix.Tasks.AshEnterprise.SiteRoutes.path()))

      assert file == Mix.Tasks.AshEnterprise.SiteRoutes.render(),
             "docs/routes.json is out of date. Run `mix ash_enterprise.site_routes` and commit it."
    end
  end

  describe "docs/failures.json" do
    test "names the tour's failures and their beats as the tour does" do
      listed =
        for f <- read_json!("docs/failures.json")["failures"],
            do: {f["id"], f["beat"], f["beat_id"]}

      assert listed == AshEnterpriseWeb.ShowcaseLive.TourIndex.failures()
    end

    test "cites tests that exist under the names given" do
      missing =
        for f <- read_json!("docs/failures.json")["failures"],
            %{"file" => file, "test" => name} <- f["tests"],
            path = Path.join(@root, file),
            not (File.exists?(path) and File.read!(path) =~ ~s(test "#{name}")),
            do: "#{f["id"]}: #{file}: #{name}"

      assert missing == []
    end
  end
end
