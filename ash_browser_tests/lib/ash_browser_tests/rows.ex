defmodule AshBrowserTests.Rows do
  @moduledoc """
  Row-level machinery for a derived browser suite over an `AshA2ui.Manifest`:
  the row ids a page shows, the ids one of the manifest's table reads returns,
  the preset picker that switches between them, and the row a row action can
  act on.

  Nothing in here knows a host: it speaks Ash, `AshA2ui.Manifest` and the
  `data-a2ui-*` attributes the manifest lists (`attributes`), so it can move
  into `ash_browser_tests` unchanged. The host supplies actors and tenants;
  reads run authorized, as the same actor the page runs them as.
  """

  alias AshBrowserTests.Browser

  # The waits below poll the page with `Process.sleep/1` between reads. That
  # is deliberate, not the sleep the test guidelines forbid: the state waited on
  # lives in Chromium, another OS process, which sends the test no message
  # when it changes, so there is nothing to monitor or `assert_receive`.
  @wait_ms 30_000
  @poll_ms 200

  @doc "How long the drivers wait for the page to show what they look for."
  def wait_ms, do: @wait_ms

  # --- What the page shows -----------------------------------------------------

  @doc """
  The `data-a2ui-row-id` values the page shows for `table`, in display order,
  deduplicated. When the table carries no `component_id` (a board or calendar
  display, or a sectioned table), every row id on the page is returned — the
  host only compares that set against one table's read when the surface has a
  single table. `attributes` is the manifest's `attributes` map (version 1
  names the row attribute `data-a2ui-row-id`).
  """
  @spec shown_ids(struct(), map(), map() | nil) :: [String.t()]
  def shown_ids(conn, table, attributes \\ %{row_id: "data-a2ui-row-id"}) do
    row_attribute = (attributes && Map.fetch!(attributes, :row_id)) || "data-a2ui-row-id"
    component = table[:component_id]

    expression = """
    (() => {
      #{Browser.walker()}
      const attr = #{Jason.encode!(row_attribute)}
      const component = #{Jason.encode!(component)}
      const roots = component
        ? deep(document, `[data-a2ui-id="${component}"]`).flatMap((el) => [el, ...(el.shadowRoot ? [el.shadowRoot] : [])])
        : [document]
      const ids = []
      for (const root of roots) {
        for (const el of deep(root, `[${attr}]`)) ids.push(el.getAttribute(attr))
      }
      return [...new Set(ids)]
    })()
    """

    Fluffy.Playwright.evaluate(conn, expression)
  end

  @doc "How long the drivers sleep between two reads of the page."
  def poll_ms, do: @poll_ms

  @doc """
  Whether `table`'s own component (`data-a2ui-id`) is on the page, and how
  many record rows the whole page shows.
  """
  @spec table_state(struct(), map(), map() | nil) :: %{
          component?: boolean(),
          page_rows: integer()
        }
  def table_state(conn, table, attributes \\ nil) do
    row_attribute = (attributes && Map.fetch!(attributes, :row_id)) || "data-a2ui-row-id"

    %{"component" => component?, "rows" => rows} =
      Fluffy.Playwright.evaluate(conn, """
      (() => {
        #{Browser.walker()}
        const component = #{Jason.encode!(to_string(table[:component_id]))}
        return {
          component: deep(document, `[data-a2ui-id="${component}"]`).length > 0,
          rows: deep(document, `[#{row_attribute}]`).length
        }
      })()
      """)

    %{component?: component?, page_rows: rows}
  end

  @doc "Every `data-a2ui-id` on the page, across shadow roots: for failure messages."
  @spec component_ids(struct()) :: [String.t()]
  def component_ids(conn) do
    Fluffy.Playwright.evaluate(conn, """
    (() => {
      #{Browser.walker()}
      return [...new Set(deep(document, "[data-a2ui-id]").map((el) => el.getAttribute("data-a2ui-id")))]
    })()
    """)
  end

  # --- What the read returns -----------------------------------------------------

  @doc """
  The ids `table`'s read returns, as the actor: the preset's read and filter
  when one is selected, the query's `default_preset` when none is, the
  table's own read otherwise; the table's `context_filter` applied from
  `opts[:contexts]` (`%{context_name => record_or_id}`), the query's default
  sort and page size mirrored. `preset` is a preset map from the manifest,
  or its name.
  """
  @spec expected(map(), map() | atom() | nil, keyword()) :: [String.t()]
  def expected(table, preset, opts) do
    preset = preset && resolve_preset(table, preset)
    read = (preset && (preset.read_action || table.read_action)) || default_view(table).read

    conditions =
      List.wrap(preset && preset[:filter]) ++
        default_view(table).filter ++ context_conditions(table, opts)

    table.resource
    |> Ash.Query.for_read(read)
    |> apply_filter_input(conditions)
    |> apply_sort(table)
    |> apply_limit(table)
    |> Ash.read!(Keyword.take(opts, [:actor, :tenant]))
    |> Enum.map(&to_string(Map.fetch!(&1, :id)))
  end

  # What the page shows before a person picks a preset: the query's
  # `default_preset` when the table declares one, the table's read otherwise.
  defp default_view(%{query: %{default_preset: name}} = table) when not is_nil(name) do
    preset = resolve_preset(table, name)
    %{read: preset.read_action || table.read_action, filter: List.wrap(preset[:filter])}
  end

  defp default_view(table), do: %{read: table.read_action, filter: []}

  defp resolve_preset(table, name) when is_atom(name) do
    Enum.find(table[:presets] || [], &(&1.name == name)) ||
      raise ArgumentError, "table #{inspect(table.id)} has no preset #{inspect(name)}"
  end

  defp resolve_preset(_table, preset), do: preset

  defp context_conditions(table, opts) do
    contexts = opts[:contexts] || %{}

    # A context without a selection leaves the read unfiltered, exactly as
    # the page renders it before a row is picked.
    for %{field: field, context: context} <- table[:context_filter] || [],
        value = Map.get(contexts, context),
        value != nil do
      %{
        field: field,
        op: :eq,
        value: if(is_struct(value), do: Map.fetch!(value, :id), else: value)
      }
    end
  end

  # --- The preset picker -----------------------------------------------------

  @doc """
  Switches the table to `preset` through the query's preset picker: opens the
  picker (an Atlas dropdown whose accessible name is the query's
  `preset_picker_label`) and chooses the preset by its accessible name. The
  write goes through the picker's own controller, exactly as a person's
  click does.
  """
  @spec select_preset(struct(), map(), map() | atom()) :: struct()
  def select_preset(conn, table, preset) do
    preset = resolve_preset(table, preset)
    picker_label = table[:query][:preset_picker_label] || "View"

    conn
    |> open_picker(picker_label)
    |> Browser.deep_click("[role='menuitemradio'], atlas-menu-item", text: preset.label)
  end

  # The toggle renders its label inside its own shadow root, and the catalog
  # may append applied counts to the name, so the match is a case-insensitive
  # prefix on aria-label or the shadow text, never on the host's textContent.
  # The query controls hydrate with the surface, so the toggle is waited for.
  defp open_picker(conn, picker_label) do
    deadline = System.monotonic_time(:millisecond) + @wait_ms
    do_open_picker(conn, picker_label, deadline)
  end

  defp do_open_picker(conn, picker_label, deadline) do
    expression = """
    (() => {
      #{Browser.walker()}
      const label = #{Jason.encode!(picker_label)}.toLowerCase()
      const named = (el) => {
        const name =
          el.getAttribute("aria-label") ||
          (el.shadowRoot && el.shadowRoot.textContent) ||
          el.textContent ||
          ""
        return name.trim().toLowerCase().startsWith(label)
      }
      const toggle = deep(document, "atlas-dropdown-toggle").find(named)
      if (!toggle) return "no picker named " + label
      const inner = toggle.shadowRoot && toggle.shadowRoot.querySelector("button")
      ;(inner || toggle).click()
      return "opened"
    })()
    """

    case Fluffy.Playwright.evaluate(conn, expression) do
      "opened" ->
        conn

      "no picker named " <> _label ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@poll_ms)
          do_open_picker(conn, picker_label, deadline)
        else
          raise ExUnit.AssertionError, message: "preset picker: no picker named #{picker_label}"
        end

      outcome ->
        raise ExUnit.AssertionError, message: "preset picker: #{outcome}"
    end
  end

  # --- The row a row action acts on --------------------------------------------

  @doc """
  The first row of `row_action`'s table, read as the actor under the table's
  default view, that satisfies the action's `visible_when`
  (`AshA2ui.Manifest.visible?/2`). `nil` when no row qualifies: the host seeds
  one or waives the action.
  """
  @spec pick(map(), map(), keyword()) :: Ash.Resource.record() | nil
  def pick(manifest, row_action, opts) do
    table = Enum.find(manifest.tables, &(&1.id == row_action.table))
    view = default_view(table)
    fields = Enum.uniq(Enum.map(row_action[:visible_when] || [], & &1.field))

    table.resource
    |> Ash.Query.for_read(view.read)
    |> apply_filter_input(view.filter)
    |> apply_sort(table)
    |> apply_limit(table)
    |> Ash.Query.load(fields)
    |> Ash.read!(Keyword.take(opts, [:actor, :tenant]))
    |> Enum.find(&AshA2ui.Manifest.visible?(row_action, &1))
  end

  defp apply_filter_input(query, []), do: query

  defp apply_filter_input(query, conditions) do
    Ash.Query.filter_input(query, AshA2ui.Manifest.filter_input(conditions))
  end

  defp apply_sort(query, %{query: %{default_sort: sort}}) when is_list(sort) and sort != [] do
    Ash.Query.sort(query, Enum.map(sort, &{&1.field, &1.direction}))
  end

  defp apply_sort(query, _table), do: query

  defp apply_limit(query, %{query: %{page_size: size}}) when is_integer(size),
    do: Ash.Query.limit(query, size)

  defp apply_limit(query, _table), do: query

  # --- Waiting ------------------------------------------------------------------

  @doc """
  Polls until the page shows exactly the expected row ids, or fails naming
  both sets. `expected` is recomputed by `expected_fn/0` on each poll, so a
  read that lands with the rows (both share the actor's transaction view)
  never races the page. `attributes` is the manifest's `attributes` map.
  """
  @spec assert_ids(struct(), map(), (-> [String.t()]), map() | nil) :: struct()
  def assert_ids(conn, table, expected_fn, attributes \\ nil) do
    deadline = System.monotonic_time(:millisecond) + @wait_ms

    do_assert_ids(conn, table, expected_fn, attributes, deadline)
  end

  defp do_assert_ids(conn, table, expected_fn, attributes, deadline) do
    shown = shown_ids(conn, table, attributes)
    expected = Enum.sort(expected_fn.())

    if Enum.sort(shown) == expected do
      conn
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(@poll_ms)
        do_assert_ids(conn, table, expected_fn, attributes, deadline)
      else
        raise ExUnit.AssertionError,
          message:
            "table #{inspect(table.id)}: rows shown != rows read\n" <>
              "  shown:    #{inspect(shown)}\n  expected: #{inspect(expected)}"
      end
    end
  end
end
