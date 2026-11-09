defmodule AshBrowserTests.Fixture.Manifest do
  @moduledoc false
  use AshBrowserTests.A2uiManifest.Static,
    manifests: %{
      "widgets" => %{
        surface_id: "widgets",
        row_actions: [%{id: "activate", label: "Activate", ash_action: :activate}]
      }
    }
end

defmodule AshBrowserTests.Fixture.Actions do
  @moduledoc false
  def create(conn, _context), do: PhoenixTest.click_button(conn, "Create widget")
end

defmodule AshBrowserTests.Fixture.Surfaces do
  @moduledoc false
  @behaviour AshBrowserTests.Surfaces.Host

  import AshBrowserTests.Trace

  alias AshBrowserTests.Action
  alias AshBrowserTests.Browser
  alias AshBrowserTests.Fixture.Endpoint
  alias AshBrowserTests.Fixture.Widget
  alias AshBrowserTests.Surface

  @impl true
  def surfaces do
    [
      %Surface{
        id: "widgets",
        path: "/widgets",
        actor: "alice",
        mounted: "#title",
        chain: [browser_connect(), live_mount(), ash_action(action: :read), query()],
        actions: [
          %Action{id: "create", run: &AshBrowserTests.Fixture.Actions.create/2},
          %Action{id: "waived-action", run: nil}
        ]
      },
      %Surface{id: "whoami", path: "/whoami", actor: "bob", mounted: "#whoami"},
      %Surface{id: "headless", path: nil}
    ]
  end

  @impl true
  def waivers do
    [
      {:surface, "headless", "no page to open; driven by a hand-written journey"},
      {:action, "widgets", "waived-action", "needs a second actor the fixture does not model"}
    ]
  end

  @impl true
  def sign_in(conn, actor, _context) do
    Browser.sign_in(conn, %{"user" => actor}, Endpoint.session_options())
  end

  @impl true
  def a2ui_manifest, do: AshBrowserTests.Fixture.Manifest

  @impl true
  def row_for(_surface, _row_action, _context) do
    name = "Row #{System.unique_integer([:positive])}"

    Widget
    |> Ash.Changeset.for_create(:create, %{name: name})
    |> Ash.create!(authorize?: false)

    %{text: name}
  end
end

defmodule AshBrowserTests.Fixture.BadSurfaces do
  @moduledoc false
  @behaviour AshBrowserTests.Surfaces.Host

  alias AshBrowserTests.Surface

  @impl true
  def surfaces do
    [%Surface{id: "console", path: "/console-error", actor: "x", mounted: "#plain"}]
  end

  @impl true
  def waivers, do: []

  @impl true
  def sign_in(conn, _actor, _context), do: conn
end

defmodule AshBrowserTests.Fixture.UnwaivedSurfaces do
  @moduledoc false
  @behaviour AshBrowserTests.Surfaces.Host

  alias AshBrowserTests.Action
  alias AshBrowserTests.Surface

  @impl true
  def surfaces do
    [
      %Surface{id: "covered", path: "/plain", actor: "x"},
      %Surface{id: "no-path-no-waiver", path: nil},
      %Surface{
        id: "action-without-run",
        path: "/plain",
        actor: "x",
        actions: [%Action{id: "unrunnable"}]
      }
    ]
  end

  @impl true
  def waivers, do: []

  @impl true
  def sign_in(conn, _actor, _context), do: conn
end
