defmodule AshBrowserTests.Surfaces do
  @moduledoc """
  Generates a browser test for every surface a host declares, and a ledger test
  that fails on anything neither exercised nor waived.

      defmodule MyAppWeb.E2E.Surfaces do
        @behaviour AshBrowserTests.Surfaces.Host
        alias AshBrowserTests.{Action, Surface}

        @impl true
        def surfaces do
          [
            %Surface{id: "orders", path: "/orders", actor: :admin},
            %Surface{id: "reports", path: "/reports", actor: :manager,
              actions: [%Action{id: "export", run: &MyAppWeb.E2E.Actions.export/2}]}
          ]
        end

        @impl true
        def waivers, do: [{:surface, "legacy-export", "server-rendered, no LiveView"}]

        @impl true
        def sign_in(conn, actor, _context), do: MyAppWeb.E2E.Login.as(conn, actor)
      end

      # test/e2e/surfaces_test.exs
      defmodule MyAppWeb.E2E.SurfacesTest do
        use AshBrowserTests.Surfaces, host: MyAppWeb.E2E.Surfaces, async: true
      end

  ## What each test asserts

  Per surface: sign in as the surface's actor, visit its path, the LiveView connects,
  the surface mounts, the span chain is intact, no console errors or 5xx. Per action:
  the same page, then `run`, then the action's chain and the same browser checks.

  ## The default chains

  A surface asserts browser connect span -> LiveView mount; an action asserts browser
  event span -> `handle_event`. Set `:chain` on a surface or action to extend them,
  for example down to `ash_action()` and `query()`.

  ## A2UI row actions

  When the host implements `c:AshBrowserTests.Surfaces.Host.a2ui_manifest/0` and
  `c:AshBrowserTests.Surfaces.Host.row_for/3`, each row action in the manifest for a
  surface becomes an action with id `"row:<id>"`.
  """

  alias AshBrowserTests.Action
  alias AshBrowserTests.Browser
  alias AshBrowserTests.Ledger
  alias AshBrowserTests.Surface
  alias AshBrowserTests.Trace

  defmodule Host do
    @moduledoc "What a host provides to the generator."

    alias AshBrowserTests.A2uiManifest
    alias AshBrowserTests.Ledger
    alias AshBrowserTests.Surface

    @doc "Every surface. Evaluated at compile time and again when a test runs."
    @callback surfaces() :: [Surface.t()]

    @doc "The waivers."
    @callback waivers() :: [Ledger.waiver()]

    @doc "Signs in as `actor`, returning the session. Called for every surface."
    @callback sign_in(conn :: struct(), actor :: term(), context :: map()) :: struct()

    @doc "The module implementing `AshBrowserTests.A2uiManifest`."
    @callback a2ui_manifest() :: module()

    @doc """
    The row a generated row-action test acts on: a map with `:text`, identifying the
    row, and `:inputs`, a map of field name to value for `prompt_fields`. `nil` fails
    the test.
    """
    @callback row_for(Surface.t(), A2uiManifest.row_action(), context :: map()) :: map() | nil

    @doc "Runs after a row action, with its correlation id, to assert an audit row."
    @callback assert_audit(correlation_id :: String.t(), context :: map()) :: any()

    @optional_callbacks a2ui_manifest: 0, row_for: 3, assert_audit: 2
  end

  defmacro __using__(opts) do
    host = Keyword.fetch!(opts, :host)
    async = Keyword.get(opts, :async, false)

    quote do
      use AshBrowserTests.Case, async: unquote(async)

      @surfaces_host unquote(host)

      for {name, generated} <- AshBrowserTests.Surfaces.generated(@surfaces_host) do
        @tag generated: generated
        test name, context do
          AshBrowserTests.Surfaces.run(@surfaces_host, context)
        end
      end

      @tag :ledger
      test "ledger: every surface and action is exercised or waived" do
        AshBrowserTests.Surfaces.assert_ledger!(@surfaces_host)
      end
    end
  end

  # --- Planning ------------------------------------------------------------------

  @doc """
  The tests to generate, as `{test_name, generated}` tuples. Raises on a duplicate id.
  """
  @spec generated(module()) :: [{String.t(), tuple()}]
  def generated(host) do
    surfaces = declared(host)
    assert_unique!(surfaces)
    waivers = host.waivers()

    surfaces
    |> Enum.reject(&(&1.path == nil or waived_surface?(waivers, &1.id)))
    |> Enum.flat_map(fn surface ->
      [
        {"surface #{surface.id}", {:surface, surface.id}}
        | surface.actions
          |> Enum.reject(&(&1.run == nil or waived_action?(waivers, surface.id, &1.id)))
          |> Enum.map(fn action ->
            {"action #{surface.id} / #{action.id}", {:action, surface.id, action.id}}
          end)
      ]
    end)
  end

  @doc "The host's surfaces, with A2UI row actions from its manifest merged in."
  @spec declared(module()) :: [Surface.t()]
  def declared(host) do
    Enum.map(host.surfaces(), &with_row_actions(&1, host))
  end

  @doc "Runs the ledger over `generated/1` and the host's waivers."
  @spec assert_ledger!(module()) :: :ok
  def assert_ledger!(host) do
    exercised = host |> generated() |> Enum.map(fn {_name, key} -> key end)
    Ledger.assert_complete!(declared(host), host.waivers(), exercised)
  end

  defp assert_unique!(surfaces) do
    ids = Enum.map(surfaces, & &1.id)
    dupes = ids -- Enum.uniq(ids)
    if dupes != [], do: raise(ArgumentError, "duplicate surface ids: #{inspect(dupes)}")

    Enum.each(surfaces, fn surface ->
      action_ids = Enum.map(surface.actions, & &1.id)
      action_dupes = action_ids -- Enum.uniq(action_ids)

      if action_dupes != [] do
        raise ArgumentError, "duplicate actions on #{surface.id}: #{inspect(action_dupes)}"
      end
    end)
  end

  defp waived_surface?(waivers, id), do: Enum.any?(waivers, &match?({:surface, ^id, _}, &1))

  defp waived_action?(waivers, surface_id, action_id) do
    Enum.any?(waivers, &match?({:action, ^surface_id, ^action_id, _}, &1))
  end

  defp with_row_actions(%Surface{} = surface, host) do
    row_actions =
      with true <- function_exported?(host, :a2ui_manifest, 0),
           manifest_module = host.a2ui_manifest(),
           %{row_actions: actions} <- manifest_module.manifest(surface.id) do
        Enum.map(actions, &row_action(&1, surface, host))
      else
        _none -> []
      end

    %{surface | actions: surface.actions ++ row_actions}
  end

  defp row_action(row_action, surface, host) do
    %Action{
      id: "row:#{row_action.id}",
      setup: &row_setup(&1, surface, row_action, host),
      run: &run_row_action(&1, &2, row_action),
      verify: &verify_row_action(&1, &2, host),
      chain: [
        Trace.browser_event(),
        Trace.handle_event(),
        Trace.ash_action(action: row_action.ash_action)
      ]
    }
  end

  # --- Running -------------------------------------------------------------------

  @doc false
  def run(host, %{generated: {:surface, id}} = context) do
    surface = fetch_surface!(host, id)
    conn = open(host, surface, context)
    conn = Browser.flush_browser_spans(conn)

    Trace.assert_chain(context.test_key, surface.chain || default_surface_chain())
    Browser.assert_no_browser_failures(conn)
  end

  def run(host, %{generated: {:action, surface_id, action_id}} = context) do
    surface = fetch_surface!(host, surface_id)
    action = Enum.find(surface.actions, &(&1.id == action_id)) || raise "no action #{action_id}"
    context = if action.setup, do: action.setup.(context), else: context

    conn = open(host, surface, context)
    conn = action.run.(conn, context)
    conn = Browser.flush_browser_spans(conn)

    spans = Trace.assert_chain(context.test_key, action.chain || default_action_chain())
    if action.verify, do: action.verify.(spans, context)
    Browser.assert_no_browser_failures(conn)
  end

  defp open(host, surface, context) do
    context.conn
    |> host.sign_in(surface.actor, context)
    |> PhoenixTest.visit(surface.path)
    |> Browser.assert_connected()
    |> PhoenixTest.assert_has(surface.mounted || "[data-phx-main]", timeout: 15_000)
  end

  defp fetch_surface!(host, id) do
    Enum.find(declared(host), &(&1.id == id)) || raise "no surface #{id}"
  end

  defp default_surface_chain, do: [Trace.browser_connect(), Trace.live_mount()]
  defp default_action_chain, do: [Trace.browser_event(), Trace.handle_event()]

  # --- Generated row actions -------------------------------------------------------

  @doc false
  def row_setup(context, surface, row_action, host) do
    row = host.row_for(surface, row_action, context)

    if row == nil do
      raise ExUnit.AssertionError,
        message:
          "no row to act on for #{surface.id} / #{row_action.id}; seed one in row_for/3 " <>
            "or waive the action"
    end

    Map.put(context, :row, row)
  end

  @doc false
  def run_row_action(conn, %{row: row}, row_action) do
    conn = click_in_row(conn, row.text, row_action.label)

    conn =
      Enum.reduce(row_action[:prompt_fields] || [], conn, fn field, acc ->
        PhoenixTest.fill_in(acc, field.label, with: Map.fetch!(row[:inputs] || %{}, field.name))
      end)

    case row_action[:confirm_label] do
      nil -> conn
      label -> Browser.deep_click(conn, "button, atlas-button", text: label)
    end
  end

  # An audit row carrying the correlation id of the action proves the action
  # actually wrote, with no domain knowledge in the generator.
  defp verify_row_action([_browser, event | _rest], context, host) do
    if function_exported?(host, :assert_audit, 2) do
      host.assert_audit(event.attributes["ash.correlation_id"], context)
    end
  end

  defp click_in_row(conn, row_text, label) do
    clicked =
      eval(conn, """
      (() => {
        #{Browser.walker()}
        const row = deep(document, 'tr, [role="row"]').find((el) => el.textContent.includes(#{Jason.encode!(row_text)}))
        if (!row) return "no row"
        const button = deep(row, 'button, atlas-button, a').find((el) => el.textContent.trim() === #{Jason.encode!(label)})
        if (!button) return "no button"
        ;(button.shadowRoot && button.shadowRoot.querySelector("button") || button).click()
        return "clicked"
      })()
      """)

    if clicked != "clicked" do
      raise ExUnit.AssertionError,
        message: "row action #{inspect(label)} in row #{inspect(row_text)}: #{clicked}"
    end

    conn
  end

  defp eval(conn, expression) do
    parent = self()
    ref = make_ref()
    PhoenixTest.Playwright.evaluate(conn, expression, &send(parent, {ref, &1}))

    receive do
      {^ref, result} -> result
    after
      5_000 -> raise ExUnit.AssertionError, message: "the page did not answer evaluate"
    end
  end
end
