defmodule AshBrowserTests.Tables do
  @moduledoc """
  Generates a browser test per A2UI table and per query preset from the
  host's `AshA2ui.Manifest`: the rows the page shows must equal the rows the
  table's read returns for the same actor, compared by `data-a2ui-row-id`,
  never by text.

  Pairs with `AshBrowserTests.Surfaces` (same host module): the surface and
  row-action tests come from there; the table and preset tests come from
  here. Tables are not part of that package's coverage ledger, so this
  module keeps its own: every table and preset is either exercised or waived
  with a written reason, and anything else fails.

  ## The host

  The same module that implements `AshBrowserTests.Surfaces.Host`, plus:

    * `c:manifests/0` — the surface id => `AshA2ui.Manifest` map (this host's
      `DerivedManifests`), which the generator iterates.
    * `c:row_opts/2` — `[actor:, tenant:]` for the reads, resolving the
      surface's door fixture for `context` (the test's map).
    * `c:context_record/3` — the record that satisfies one of a table's
      `require_context` names, so detail tables can be opened through the
      surface's `?ctx[<name>]=<id>` deep link. `nil` fails the test.
    * `c:seed_table/3` (optional) — seeds rows the table's read returns
      before the page opens.

  `c:table_waivers/0` on the host carries this ledger's waivers
  (`{:table, surface, table, reason}` or `{:preset, surface, table, preset,
  reason}`); the host's `waivers/0` stays the surface/action list
  `AshBrowserTests.Ledger` takes.

  ## A comparison must compare something

  An empty read equals an empty page before the grid has hydrated, so an
  empty read proves nothing. A test first waits for the table's own
  component (`data-a2ui-id`), then fails when the read returns no rows,
  unless the table (or the preset) is listed as `{:empty, surface, table,
  reason}` (or `{:empty, surface, table, preset, reason}`): rows seeded by
  `c:seed_table/3` or `c:context_record/3` are what make a comparison count.
  """

  alias AshBrowserTests.Browser
  alias AshBrowserTests.Rows

  defmodule Host do
    @moduledoc "The callbacks `AshBrowserTests.Tables` adds to the surfaces host."

    @doc "The surface id => `AshA2ui.Manifest` map the generator iterates."
    @callback manifests() :: %{String.t() => map()}

    @doc "`[actor:, tenant:]` for reads as the surface's actor, fixtures resolved for `context`."
    @callback row_opts(surface :: struct(), context :: map()) :: keyword()

    @doc "This ledger's waivers: `{:table, surface, table, reason}` or `{:preset, surface, table, preset, reason}`."
    @callback table_waivers() :: [tuple()]

    @doc "The record answering one of a table's `require_context` names, or `nil`."
    @callback context_record(surface :: struct(), context :: atom(), context_map :: map()) ::
                Ash.Resource.record() | String.t() | nil

    @doc "Seeds rows `table`'s read returns for the surface's actor, before the page opens."
    @callback seed_table(surface :: struct(), table :: map(), context_map :: map()) :: term()

    @optional_callbacks seed_table: 3
  end

  defmacro __using__(opts) do
    host = Keyword.fetch!(opts, :host)
    async = Keyword.get(opts, :async, false)

    quote do
      use AshBrowserTests.Case, async: unquote(async)

      @tables_host unquote(host)

      for {name, plan} <- AshBrowserTests.Tables.generated(@tables_host) do
        @tag plan: plan
        test name, context do
          AshBrowserTests.Tables.run(@tables_host, context)
        end
      end

      @tag :table_ledger
      test "table ledger: every A2UI table and preset is exercised or waived" do
        AshBrowserTests.Tables.assert_ledger!(@tables_host)
      end
    end
  end

  # --- Planning ------------------------------------------------------------------

  @doc "The tests to generate, as `{test_name, plan}` tuples."
  def generated(host) do
    assert_unique!(host.surfaces())
    waivers = host.table_waivers()
    manifests = manifests(host)

    host.surfaces()
    |> Enum.reject(&(is_nil(&1.path) or surface_waived?(host, &1.id)))
    |> Enum.flat_map(fn surface ->
      with_manifest(surface, manifests, fn manifest ->
        table_tests(surface, manifest, waivers)
      end)
    end)
  end

  defp table_tests(surface, manifest, waivers) do
    waived = MapSet.new(waived_keys(waivers))

    Enum.flat_map(manifest.tables, fn table ->
      if MapSet.member?(waived, {:table, surface.id, table.id, nil}) do
        []
      else
        table_plan(surface, table, waived)
      end
    end)
  end

  defp table_plan(surface, table, waived) do
    presets =
      for preset <- switchable_presets(table),
          plan = {:preset, surface.id, table.id, preset.name},
          not MapSet.member?(waived, plan) do
        {"preset #{surface.id} / #{table.id} / #{preset.name}", plan}
      end

    [{"table #{surface.id} / #{table.id}", {:table, surface.id, table.id, nil}} | presets]
  end

  # A preset a person cannot switch to (the page sets it itself,
  # `preset_picker false`; the manifest then carries no
  # `preset_picker_label`) has no browser test; the table's default view —
  # which is that default preset's read — is the test that covers it. The
  # ledger counts those obligations as covered, with this stated reason.
  defp switchable_presets(table) do
    if picker?(table), do: table.presets, else: []
  end

  defp picker?(%{query: %{preset_picker_label: nil}}), do: false
  defp picker?(%{query: %{preset_picker: false}}), do: false
  defp picker?(_table), do: true

  @doc "Runs the table ledger over the generated tests and the host's table waivers."
  def assert_ledger!(host) do
    waivers = host.table_waivers()
    exercised = host |> generated() |> Enum.map(fn {_name, plan} -> plan end)
    obligations = obligations(host)

    problems =
      uncovered(obligations, covered(host, waivers, exercised)) ++
        stale_waivers(waivers, obligations) ++ reasons_missing(waivers)

    if problems != [] do
      raise ExUnit.AssertionError,
        message:
          "the derived table suite is incomplete:\n" <>
            Enum.map_join(problems, "\n", &"  #{&1}")
    end

    :ok
  end

  # The obligations come from the manifests alone, never from the plans: every
  # table of every manifest, and every one of its presets. A table the
  # generator drops (a surface without a path, a manifest keyed by an id no
  # surface carries, a filter gone wrong) is then uncovered, not invisible.
  defp obligations(host) do
    host
    |> manifests()
    |> Enum.reject(fn {_surface_id, manifest} -> is_nil(manifest) end)
    |> Enum.flat_map(fn {surface_id, manifest} ->
      Enum.flat_map(manifest.tables, fn table ->
        [
          {:table, surface_id, table.id, nil}
          | Enum.map(table[:presets] || [], &{:preset, surface_id, table.id, &1.name})
        ]
      end)
    end)
    |> MapSet.new()
  end

  # What covers an obligation: a generated test; a waiver; a waived surface
  # (its tables go with it); and, for a preset nobody can switch to, the
  # test of its table's default view, which is that preset's read.
  defp covered(host, waivers, exercised) do
    exercised = MapSet.new(exercised)
    manifests = manifests(host)

    waived_surfaces =
      for {:surface, id, _reason} <- host.waivers(),
          manifest = manifests[id],
          manifest,
          table <- manifest.tables,
          key <- [
            {:table, id, table.id, nil}
            | Enum.map(table[:presets] || [], &{:preset, id, table.id, &1.name})
          ],
          do: key

    pickerless =
      for {surface_id, manifest} <- manifests,
          manifest,
          table <- manifest.tables,
          not picker?(table),
          MapSet.member?(exercised, {:table, surface_id, table.id, nil}),
          preset <- table[:presets] || [],
          do: {:preset, surface_id, table.id, preset.name}

    exercised
    |> MapSet.union(MapSet.new(waived_keys(waivers)))
    |> MapSet.union(MapSet.new(waived_surfaces))
    |> MapSet.union(MapSet.new(pickerless))
  end

  defp uncovered(obligations, covered) do
    obligations
    |> MapSet.difference(covered)
    |> Enum.sort()
    |> Enum.map(fn
      {:table, surface, table, nil} ->
        "table #{inspect(table)} on surface #{inspect(surface)} has no test and no waiver"

      {:preset, surface, table, preset} ->
        "preset #{inspect(preset)} of table #{inspect(table)} on surface #{inspect(surface)} " <>
          "has no test and no waiver"
    end)
  end

  defp waived_keys(waivers) do
    Enum.flat_map(waivers, fn
      {:table, surface, table, _reason} -> [{:table, surface, table, nil}]
      {:preset, surface, table, preset, _reason} -> [{:preset, surface, table, preset}]
      _other -> []
    end)
  end

  defp stale_waivers(waivers, obligations) do
    Enum.flat_map(waivers, &stale_waiver(&1, waiver_key(&1), obligations))
  end

  defp stale_waiver(waiver, nil, _obligations) do
    [
      "waiver #{inspect(waiver)} is none of {:table, s, t, reason}, " <>
        "{:preset, s, t, p, reason}, {:empty, s, t, reason} or {:empty, s, t, p, reason}"
    ]
  end

  defp stale_waiver(waiver, key, obligations) do
    if MapSet.member?(obligations, key),
      do: [],
      else: ["waiver #{inspect(waiver)} names nothing declared; remove it"]
  end

  defp waiver_key({:table, surface, table, _reason}), do: {:table, surface, table, nil}

  defp waiver_key({:preset, surface, table, preset, _reason}),
    do: {:preset, surface, table, preset}

  defp waiver_key({:empty, surface, table, _reason}), do: {:table, surface, table, nil}

  defp waiver_key({:empty, surface, table, preset, _reason}),
    do: {:preset, surface, table, preset}

  defp waiver_key(_other), do: nil

  defp reasons_missing(waivers) do
    for waiver <- waivers,
        reason = elem(waiver, tuple_size(waiver) - 1),
        not (is_binary(reason) and String.trim(reason) != "") do
      "waiver #{inspect(waiver)} has no reason"
    end
  end

  # Whether the plan's read may come back empty (an `{:empty, ...}` waiver).
  defp empty_allowed?(waivers, {:table, surface, table, nil}),
    do: Enum.any?(waivers, &match?({:empty, ^surface, ^table, _reason}, &1))

  defp empty_allowed?(waivers, {:preset, surface, table, preset}),
    do: Enum.any?(waivers, &match?({:empty, ^surface, ^table, ^preset, _reason}, &1))

  # --- Running -------------------------------------------------------------------

  @doc false
  def run(host, %{plan: {kind, surface_id, table_id, preset} = plan} = context)
      when kind in [:table, :preset] do
    surface = fetch_surface!(host, surface_id)
    run_table(host, surface, table_id, preset, plan, context)
  end

  defp run_table(host, surface, table_id, preset, plan, context) do
    manifest = fetch_manifest!(host, surface.id)
    table = Enum.find(manifest.tables, &(&1.id == table_id)) || raise("no table #{table_id}")
    opts = host.row_opts(surface, context)

    # A table that reads nothing until one of its `require_context` contexts
    # is selected opens through the surface's own deep link, seeded by the
    # host; a table with an OPTIONAL context filter is compared in its
    # unfiltered view, exactly as the page renders it before a selection.
    contexts = contexts(host, surface, table, context)
    if function_exported?(host, :seed_table, 3), do: host.seed_table(surface, table, context)

    expected = fn -> Rows.expected(table, preset, opts ++ [contexts: contexts]) end
    assert_rows_to_compare!(host, plan, expected.())

    conn = open(host, surface, context, contexts)
    {conn, table} = await_table(conn, table, manifest)
    conn = if preset, do: Rows.select_preset(conn, table, preset), else: conn

    # The page and the read share the actor; give both a moment to land.
    Rows.assert_ids(conn, table, expected, Map.get(manifest, :attributes))

    Browser.assert_no_browser_failures(conn)
  end

  defp assert_rows_to_compare!(host, plan, []) do
    empty_allowed?(host.table_waivers(), plan) ||
      raise ExUnit.AssertionError,
        message:
          "#{inspect(plan)}: the read returns no rows for the actor, so the comparison " <>
            "would pass before the grid hydrates: seed a row (the host's seed_table/3 or " <>
            "context_record/3) or waive it as {:empty, ...} with a reason"
  end

  defp assert_rows_to_compare!(_host, _plan, _rows), do: true

  # The table's own component must be on the page before its rows are read:
  # with no such element, `Rows.shown_ids/3` reads nothing, which would
  # equal an empty read. Two shapes have no element to wait for: a table
  # drawn without a component id (a board or a calendar), whose rows are
  # what is waited for; and the only table of a surface that draws its rows
  # as record rows outside the component (the steward queue), whose rows
  # are then read from the whole page. Neither applies to an empty read: an
  # `{:empty, ...}` table must show its component.
  defp await_table(conn, %{component_id: nil} = table, _manifest), do: {conn, table}

  defp await_table(conn, table, manifest) do
    deadline = System.monotonic_time(:millisecond) + Rows.wait_ms()
    do_await_table(conn, table, manifest, deadline)
  end

  defp do_await_table(conn, table, manifest, deadline) do
    state = Rows.table_state(conn, table, Map.get(manifest, :attributes))

    cond do
      state.component? ->
        {conn, table}

      length(manifest.tables) == 1 and state.page_rows > 0 ->
        {conn, %{table | component_id: nil}}

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(Rows.poll_ms())
        do_await_table(conn, table, manifest, deadline)

      true ->
        raise ExUnit.AssertionError,
          message:
            "table #{inspect(table.id)} never rendered: no [data-a2ui-id=#{inspect(table.component_id)}]\n" <>
              "  components on the page: #{inspect(Rows.component_ids(conn))}"
    end
  end

  defp contexts(host, surface, table, context) do
    names = table[:require_context] || []

    if names == [] do
      %{}
    else
      Map.new(names, fn name ->
        {name,
         host.context_record(surface, name, context) ||
           raise(
             ExUnit.AssertionError,
             message:
               "no seeded record for context #{inspect(name)} on #{inspect(surface.id)}: " <>
                 "seed one in context_record/3 or waive the table"
           )}
      end)
    end
  end

  defp open(host, surface, context, contexts) do
    context.conn
    |> host.sign_in(surface.actor, context)
    |> PhoenixTest.visit(path_with_contexts(surface.path, contexts))
    |> Browser.assert_connected()
    |> PhoenixTest.assert_has(surface.mounted || "[data-phx-main]", timeout: 15_000)
  end

  # A context the path already names is not repeated in the query: a record
  # page (`/app/contracts/<id>`) selects its own record from the path.
  defp path_with_contexts(path, contexts) do
    segments = String.split(path, "/")

    query =
      for {name, record} <- contexts,
          id = to_string(if is_struct(record), do: Map.fetch!(record, :id), else: record),
          id not in segments do
        "ctx[#{name}]=#{URI.encode_www_form(id)}"
      end

    if query == [], do: path, else: "#{path}?#{Enum.join(query, "&")}"
  end

  # --- Host helpers ----------------------------------------------------------------

  defp manifests(host) do
    if function_exported?(host, :manifests, 0) do
      host.manifests()
    else
      raise ArgumentError,
            "the host must implement manifests/0 (surface id => AshA2ui.Manifest) for table tests"
    end
  end

  defp with_manifest(surface, manifests, fun) do
    case manifests[surface.id] do
      nil -> []
      manifest -> fun.(manifest)
    end
  end

  defp fetch_manifest!(host, surface_id) do
    manifests(host)[surface_id] ||
      raise "surface #{inspect(surface_id)} declares no A2UI manifest"
  end

  defp fetch_surface!(host, id) do
    Enum.find(host.surfaces(), &(&1.id == id)) || raise "no surface #{id}"
  end

  defp surface_waived?(host, id) do
    Enum.any?(host.waivers(), &match?({:surface, ^id, _}, &1))
  end

  defp assert_unique!(surfaces) do
    ids = Enum.map(surfaces, & &1.id)
    dupes = ids -- Enum.uniq(ids)
    dupes == [] || raise(ArgumentError, "duplicate surface ids: #{inspect(dupes)}")
  end
end
