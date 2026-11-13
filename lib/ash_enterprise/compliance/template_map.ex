defmodule AshEnterprise.Compliance.TemplateMap do
  @moduledoc """
  The `soc2` pack's map of `ash_compliance`'s operator process templates to this
  application: for each template, the recipe that starts it, the recipe or process
  something else already provides, or the reason no audited event can start it.

  The map is the `templates` list in `priv/packs/soc2/pack.json`. A row names one template
  (`template`) and exactly one of:

    * `recipe`: the key of a recipe in this pack. Its `process_key` is a process in this
      pack. A template that runs on a schedule (`ash_compliance` says so) has
      `"trigger": "schedule"` and a guard on the `compliance.review_due` occurrence the
      `AshEnterprise.Compliance.ScheduledReviewWorker` records for that template.
    * `reference`: `{"pack": name, "recipe": key}`, a recipe another pack already installs,
      or `{"file": path}`, a process the application already ships. Reused, not copied.
    * `reason`: why no audited event can start the template. A row without one is refused.

  `problems/2` returns what is wrong with a map, as text; an empty list is a map in which
  every template has exactly one row, no row is empty or double, and no recipe of the pack
  is left over. It says the map is consistent, not that any control operates.
  """

  alias AshCompliance.Processes.Templates
  alias AshEnterprise.Bpmn.Packs

  @pack "soc2"
  @due_type "compliance.review_due"

  @doc "The pack the map lives in."
  @spec pack() :: String.t()
  def pack, do: @pack

  @doc "The manifest of pack `name` under `root`, decoded, or an error."
  @spec manifest(String.t(), Path.t()) :: {:ok, map()} | {:error, String.t()}
  # `name` is checked against the packs `Packs.names/1` lists under `root` before it is joined to
  # a path, so it is never a path from input; Sobelow's low-confidence finding is a false positive.
  # sobelow_skip ["Traversal.FileModule"]
  def manifest(name, root \\ Packs.root()) do
    if name in Packs.names(root) do
      with {:ok, body} <- File.read(Path.join([root, name, "pack.json"])),
           {:ok, %{} = manifest} <- Jason.decode(body) do
        {:ok, manifest}
      else
        _ -> {:error, "pack #{name} has no readable pack.json"}
      end
    else
      {:error, "no pack named #{inspect(name)}"}
    end
  end

  @doc """
  What is wrong with `manifest`'s `templates` list. Options: `:templates` (default
  `ash_compliance`'s), `:packs` (manifests of the other packs, by name, for references)
  and `:root` (the directory `file` references resolve against, default the working
  directory).
  """
  @spec problems(map(), keyword()) :: [String.t()]
  def problems(manifest, opts \\ []) do
    templates = Keyword.get(opts, :templates, Templates.all())
    packs = Keyword.get(opts, :packs, %{})
    root = Keyword.get(opts, :root, File.cwd!())
    rows = Map.get(manifest, "templates", [])

    context = %{
      templates: Map.new(templates, &{&1.key, &1}),
      recipes: Map.new(Map.get(manifest, "recipes", []), &{&1["key"], &1}),
      processes: MapSet.new(Map.get(manifest, "processes", []), & &1["key"]),
      packs: packs,
      root: root
    }

    coverage(rows, templates) ++
      Enum.flat_map(rows, &row(&1, context)) ++
      unused_recipes(rows, context.recipes)
  end

  defp coverage(rows, templates) do
    named = Enum.map(rows, & &1["template"])

    for template <- templates, count = Enum.count(named, &(&1 == template.key)), count != 1 do
      "template #{template.key} has #{count} rows, not one"
    end ++
      for name <- Enum.uniq(named), name not in Enum.map(templates, & &1.key) do
        "row for #{inspect(name)}, which is not a template"
      end
  end

  defp row(%{"template" => name} = row, context) do
    kinds = for key <- ~w(recipe reference reason), Map.has_key?(row, key), do: key

    case kinds do
      [] -> ["#{name}: neither a recipe, a reference nor a reason"]
      [_, _ | _] -> ["#{name}: more than one of recipe, reference and reason"]
      [kind] -> kind(kind, row, context) ++ schedule(row, context.templates[name], context)
    end
  end

  defp row(row, _context), do: ["a row names no template: #{inspect(row)}"]

  defp kind("reason", %{"template" => name, "reason" => reason}, _context) do
    if is_binary(reason) and String.trim(reason) != "",
      do: [],
      else: ["#{name}: the reason is blank"]
  end

  defp kind("recipe", %{"template" => name, "recipe" => key}, context) do
    case context.recipes[key] do
      nil ->
        ["#{name}: recipe #{inspect(key)} is not in the pack"]

      recipe ->
        if recipe["process_key"] in context.processes,
          do: [],
          else: ["#{name}: recipe #{key} starts a process the pack does not hold"]
    end
  end

  defp kind("reference", %{"template" => name, "reference" => %{"file" => file}}, context) do
    if is_binary(file) and File.exists?(Path.join(context.root, file)),
      do: [],
      else: ["#{name}: referenced file #{inspect(file)} does not exist"]
  end

  defp kind(
         "reference",
         %{"template" => name, "reference" => %{"pack" => pack, "recipe" => key}},
         context
       ) do
    recipes = context.packs |> Map.get(pack, %{}) |> Map.get("recipes", [])

    if Enum.any?(recipes, &(&1["key"] == key)),
      do: [],
      else: ["#{name}: pack #{inspect(pack)} has no recipe #{inspect(key)}"]
  end

  defp kind("reference", %{"template" => name}, _context),
    do: ["#{name}: a reference names a file, or a pack and a recipe"]

  # A scheduled template is started by its period falling due, and only that; any other is
  # not on a schedule.
  defp schedule(%{"template" => name} = row, %{trigger: :schedule}, context) do
    guard = get_in(context.recipes, [row["recipe"], "guard_feel"])

    cond do
      row["trigger"] != "schedule" ->
        ["#{name}: runs on a schedule, so its row says trigger schedule"]

      not Map.has_key?(row, "recipe") ->
        ["#{name}: runs on a schedule and has no recipe in the pack"]

      is_binary(guard) and guard =~ @due_type and guard =~ ~s|"#{name}"| ->
        []

      true ->
        ["#{name}: its recipe does not wait for #{@due_type} for this template"]
    end
  end

  defp schedule(%{"template" => name, "trigger" => "schedule"}, _template, _context),
    do: ["#{name}: is not scheduled by ash_compliance, so its row cannot say it is"]

  defp schedule(_row, _template, _context), do: []

  defp unused_recipes(rows, recipes) do
    used = Enum.map(rows, & &1["recipe"])

    for {key, _recipe} <- recipes, Enum.count(used, &(&1 == key)) != 1 do
      "recipe #{key} is used by #{Enum.count(used, &(&1 == key))} rows, not one"
    end
  end
end
