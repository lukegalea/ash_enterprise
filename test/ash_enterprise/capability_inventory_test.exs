defmodule AshEnterprise.CapabilityInventoryTest do
  @moduledoc """
  Keeps `docs/capabilities.json` honest. The inventory grades each capability
  existing, partial, missing or refused; this test refuses a grade that its
  evidence does not carry.

  An existing or partial row must cite a test, by file and exact name, that is
  defined where it says and runs by default. A test cited from a dependency's
  own suite counts only when that dependency is pinned to one exact revision,
  so the file read is the file run. The pinned versions must be what
  `mix.lock` locks: a dependency that moves fails this test until someone
  re-reads the rows resting on it and moves the pin.
  """
  use ExUnit.Case, async: true

  alias AshEnterprise.Test.CapabilityInventory, as: Inventory

  setup_all do
    inventory = Inventory.load!()

    %{
      rows: inventory["capabilities"],
      areas: Enum.map(inventory["areas"], & &1["id"]),
      pins: inventory["pins"],
      locked: Inventory.locked()
    }
  end

  describe "the rows" do
    test "each has a unique id, a known area and status, and says what it is", ctx do
      ids = Enum.map(ctx.rows, & &1["id"])
      assert ids -- Enum.uniq(ids) == [], "duplicate capability ids"

      bad =
        Enum.reject(ctx.rows, fn row ->
          row["area"] in ctx.areas and row["status"] in Inventory.statuses() and
            present?(row["capability"]) and present?(row["summary"]) and
            is_list(row["tests"]) and is_list(row["deps"])
        end)

      assert bad == [], "malformed rows: #{inspect(Enum.map(bad, & &1["id"]))}"
    end

    test "every area has rows", ctx do
      empty = Enum.reject(ctx.areas, fn area -> Enum.any?(ctx.rows, &(&1["area"] == area)) end)
      assert empty == [], "areas with no capabilities: #{inspect(empty)}"
    end

    test "a partial row says what is missing, and a refused row says why", ctx do
      silent =
        for row <- ctx.rows,
            row["status"] in ~w(partial refused),
            not present?(row["gap"]),
            do: row["id"]

      assert silent == [], "partial or refused rows without a gap: #{inspect(silent)}"
    end

    test "every existing or partial row names a test", ctx do
      untested =
        for row <- ctx.rows,
            row["status"] in ~w(existing partial),
            row["tests"] == [],
            do: row["id"]

      assert untested == [],
             "rows claiming more than missing with no test to show it: #{inspect(untested)}"
    end

    test "a missing row names no test: if one demonstrates something, the row is partial",
         ctx do
      contradicted =
        for row <- ctx.rows, row["status"] == "missing", row["tests"] != [], do: row["id"]

      assert contradicted == [], "missing rows that cite tests: #{inspect(contradicted)}"
    end
  end

  describe "the tests the rows cite" do
    test "every cited file exists", ctx do
      absent =
        for {id, ref} <- refs(ctx.rows),
            path = resolve(ref),
            not File.regular?(path),
            do: "#{id}: #{label(ref)}"

      assert absent == [], "cited test files that do not exist:\n" <> Enum.join(absent, "\n")
    end

    test "every cited test is defined in its file under its exact name", ctx do
      undefined =
        for {id, ref} <- refs(ctx.rows),
            path = resolve(ref),
            File.regular?(path),
            test_line(File.read!(path), ref["test"]) == nil,
            do: "#{id}: #{label(ref)} -- #{inspect(ref["test"])}"

      assert undefined == [],
             "cited tests not found (renamed or removed?):\n" <> Enum.join(undefined, "\n")
    end

    test "no cited test of this project is excluded from the default run", ctx do
      excluded_tags =
        for tag <- ExUnit.configuration()[:exclude], is_atom(tag), tag != :test, do: tag

      skipped =
        for {id, ref} <- refs(ctx.rows),
            not Map.has_key?(ref, "dep"),
            path = resolve(ref),
            File.regular?(path),
            source = File.read!(path),
            tag = excluded_by(source, ref["test"], excluded_tags),
            do: "#{id}: #{label(ref)} is tagged #{inspect(tag)}"

      assert skipped == [],
             "cited tests that the default run skips:\n" <> Enum.join(skipped, "\n")
    end

    test "a test from a dependency's suite is read at a revision pinned exactly", ctx do
      exact = for pin <- ctx.pins, Map.has_key?(pin, "lock"), into: MapSet.new(), do: pin["dep"]

      loose =
        for {id, %{"dep" => dep} = ref} <- refs(ctx.rows),
            not MapSet.member?(exact, dep),
            do: "#{id}: #{label(ref)}"

      assert loose == [],
             "tests cited from dependencies without an exact pin:\n" <> Enum.join(loose, "\n")
    end
  end

  describe "the pins" do
    test "each pins a dependency in mix.lock, either exactly or by a range", ctx do
      bad =
        for pin <- ctx.pins,
            not Map.has_key?(ctx.locked, pin["dep"]) or
              Map.has_key?(pin, "lock") == Map.has_key?(pin, "requirement"),
            do: pin["dep"]

      assert bad == [],
             "pins naming no locked dependency, or not exactly one of lock/requirement: " <>
               inspect(bad)
    end

    test "an exact pin is what mix.lock locks", ctx do
      moved =
        for %{"dep" => dep, "lock" => pinned} <- ctx.pins,
            {_kind, locked} = Map.fetch!(ctx.locked, dep),
            locked != pinned,
            do:
              "#{dep}: inventory read at #{pinned}, mix.lock has #{inspect(locked)}; " <>
                "re-read #{inspect(resting_on(ctx.rows, dep))} and move the pin"

      assert moved == [], Enum.join(moved, "\n")
    end

    test "a range pin admits what mix.lock locks", ctx do
      outside =
        for %{"dep" => dep, "requirement" => requirement} <- ctx.pins,
            {:hex, version} = Map.fetch!(ctx.locked, dep),
            not Version.match?(version, requirement),
            do:
              "#{dep} #{version} is outside #{requirement}; " <>
                "re-read #{inspect(resting_on(ctx.rows, dep))} and widen or move the range"

      assert outside == [], Enum.join(outside, "\n")
    end

    test "every dependency a row rests on is pinned, and every pin is rested on", ctx do
      pinned = MapSet.new(ctx.pins, & &1["dep"])

      named =
        MapSet.new(
          Enum.flat_map(ctx.rows, fn row ->
            row["deps"] ++ for(%{"dep" => dep} <- row["tests"], do: dep)
          end)
        )

      assert MapSet.difference(named, pinned) == MapSet.new(), "rows name unpinned dependencies"
      assert MapSet.difference(pinned, named) == MapSet.new(), "pins no row rests on"
    end
  end

  defp refs(rows), do: for(row <- rows, ref <- row["tests"], do: {row["id"], ref})

  defp resolve(ref) do
    {:ok, path} = Inventory.test_path(ref)
    path
  end

  defp label(%{"dep" => dep, "file" => file}), do: "#{dep}:#{file}"
  defp label(%{"file" => file}), do: file

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # The index of the `test "<name>"` line among the source's lines, or nil.
  defp test_line(_source, name) when not is_binary(name), do: nil

  defp test_line(source, name) do
    pattern = ~r/^\s*test\s+"#{Regex.escape(name)}"/

    source
    |> String.split("\n")
    |> Enum.find_index(&Regex.match?(pattern, &1))
  end

  # The excluded tag that would skip this test: a module or describe tag
  # anywhere in the file (erring towards reporting), or a @tag directly above it.
  defp excluded_by(source, name, tags) do
    lines = String.split(source, "\n")
    index = test_line(source, name)

    above =
      lines
      |> Enum.take(index || 0)
      |> Enum.reverse()
      |> Enum.take_while(&(not Regex.match?(~r/^\s*(test|describe|end)\b/, &1)))

    Enum.find(tags, fn tag ->
      Regex.match?(~r/@(moduletag|describetag)\s+(:#{tag}\b|#{tag}:)/, source) or
        Enum.any?(above, &Regex.match?(~r/@tag\s+(:#{tag}\b|#{tag}:)/, &1))
    end)
  end

  defp resting_on(rows, dep) do
    for row <- rows,
        dep in row["deps"] or Enum.any?(row["tests"], &(&1["dep"] == dep)),
        do: row["id"]
  end
end
