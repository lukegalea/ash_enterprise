defmodule AshBrowserTests.Fixture.Migration do
  @moduledoc false
  use Ecto.Migration

  def up do
    Oban.Migrations.up()

    create table(:widgets, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :text, null: false)
      add(:active, :boolean, null: false, default: false)
    end
  end

  def down, do: :ok
end

defmodule AshBrowserTests.Fixture.Repo do
  @moduledoc false
  use AshPostgres.Repo, otp_app: :ash_browser_tests, warn_on_missing_ash_functions?: false

  @impl true
  def installed_extensions, do: ["uuid-ossp", "citext"]

  @impl true
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end

defmodule AshBrowserTests.Fixture.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered?(true)
  end
end

defmodule AshBrowserTests.Fixture.Widget do
  @moduledoc false
  use Ash.Resource,
    domain: AshBrowserTests.Fixture.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshA2ui]

  postgres do
    table("widgets")
    repo(AshBrowserTests.Fixture.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:active, :boolean, allow_nil?: false, default: false, public?: true)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:name])
    end

    update :activate do
      accept([])
      change(set_attribute(:active, true))
    end

    destroy(:remove)
  end

  # The surface journeys act on: its manifest names the table and row actions
  # `JourneyWidgetsLive` draws, and the journey verifiers check against.
  a2ui do
    surface_id("widgets")
    title("Widgets")

    component :table, :widgets do
      fields([:name, :active])
      row_actions([:activate, :remove])
    end

    action :activate do
      visible_when(active: false)
    end
  end
end

defmodule AshBrowserTests.Fixture.Worker do
  @moduledoc false
  use Oban.Worker, queue: :default

  @impl true
  def perform(_job), do: :ok
end

defmodule AshBrowserTests.Fixture.ErrorHTML do
  @moduledoc false
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule AshBrowserTests.Fixture.Layouts do
  @moduledoc false
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Fixture</title>
      </head>
      <body>
        {@inner_content}
        <script src="/vendor/phoenix/phoenix.min.js">
        </script>
        <script src="/vendor/live_view/phoenix_live_view.min.js">
        </script>
        <script type="module" src="/assets/app.js">
        </script>
      </body>
    </html>
    """
  end
end

defmodule AshBrowserTests.Fixture.WidgetsLive do
  @moduledoc false
  use Phoenix.LiveView

  alias AshBrowserTests.Fixture.Widget
  alias AshBrowserTests.Fixture.Worker
  alias AshEnterprise.Telemetry

  @impl true
  def mount(params, _session, socket) do
    widgets = if connected?(socket), do: read_widgets(), else: []
    {:ok, assign(socket, widgets: widgets, fake: params["fake"], oban: params["oban"] == "1")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1 id="title">Widgets</h1>
    <button id="create-widget" phx-click="create">Create widget</button>
    <button id="crash" phx-click="crash">Crash</button>
    <table>
      <tbody id="rows">
        <tr :for={widget <- @widgets} id={"row-#{widget.id}"}>
          <td>{widget.name}</td>
          <td>{if widget.active, do: "active", else: "inactive"}</td>
          <td>
            <button phx-click="activate" phx-value-id={widget.id}>Activate</button>
          </td>
        </tr>
      </tbody>
    </table>
    <deep-box id="deep"></deep-box>
    """
  end

  @impl true
  def handle_event("create", _params, socket) do
    Widget
    |> Ash.Changeset.for_create(:create, %{name: "Widget"})
    |> Ash.create!(authorize?: false)

    if socket.assigns.oban, do: {:ok, _job} = Oban.insert(Worker.new(%{}))
    if socket.assigns.fake, do: call_fake(socket.assigns.fake)
    {:noreply, assign(socket, :widgets, read_widgets())}
  end

  def handle_event("activate", %{"id" => id}, socket) do
    Widget
    |> Ash.get!(id, authorize?: false)
    |> Ash.Changeset.for_update(:activate, %{})
    |> Ash.update!(authorize?: false)

    {:noreply, assign(socket, :widgets, read_widgets())}
  end

  def handle_event("crash", _params, _socket), do: raise("fixture crash in handle_event")

  defp read_widgets do
    Widget |> Ash.Query.for_read(:read) |> Ash.read!(authorize?: false)
  end

  defp call_fake(url) do
    Req.new(url: url <> "/called", retry: false)
    |> Telemetry.Req.attach()
    |> Req.post!(json: %{"from" => "fixture"})
  end
end

defmodule AshBrowserTests.Fixture.JourneyWidgetsLive do
  @moduledoc false
  # The widgets as an A2UI table would draw them, from the surface's manifest:
  # rows carry `data-a2ui-row-id`, row actions `data-a2ui-action` around a
  # button named by the manifest's label, a destructive action asks in a
  # dialog, and the header shows a request-time label a figure masks. Widgets
  # named "Untraced…" are activated around Ash, so their action leaves no span.
  use Phoenix.LiveView

  import Ecto.Query, only: [from: 2]

  alias AshBrowserTests.Fixture.Repo
  alias AshBrowserTests.Fixture.Widget

  @impl true
  def mount(_params, _session, socket) do
    manifest = AshA2ui.Manifest.for_surface(Widget, catalog: :admin_v1)
    widgets = if connected?(socket), do: read_widgets(), else: []

    {:ok,
     assign(socket,
       table: hd(manifest.tables),
       actions: manifest.row_actions,
       widgets: widgets,
       confirming: nil,
       as_of: Time.utc_now() |> Time.truncate(:second) |> Time.to_string()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1 id="title">Widgets</h1>
    <p>As of <span id="as-of">{@as_of}</span></p>
    <table data-a2ui-id={@table.component_id}>
      <tbody>
        <tr :for={widget <- @widgets} data-a2ui-row-id={widget.id}>
          <td>{widget.name}</td>
          <td>{if widget.active, do: "active", else: "inactive"}</td>
          <td>
            <span
              :for={action <- @actions}
              :if={AshA2ui.Manifest.visible?(action, widget)}
              data-a2ui-action={action.ash_action}
            >
              <button phx-click="row_action" phx-value-action={action.id} phx-value-id={widget.id}>
                {action.label}
              </button>
            </span>
          </td>
        </tr>
      </tbody>
    </table>
    <div :if={@confirming} role="dialog" aria-modal="true" id="confirm">
      <p>Remove {@confirming.widget.name}?</p>
      <button phx-click="confirm">{@confirming.action.confirm_label}</button>
    </div>
    """
  end

  @impl true
  def handle_event("row_action", %{"action" => id, "id" => widget_id}, socket) do
    action = Enum.find(socket.assigns.actions, &(&1.id == id))
    widget = Ash.get!(Widget, widget_id, authorize?: false)

    if action.confirm do
      {:noreply, assign(socket, :confirming, %{action: action, widget: widget})}
    else
      run(action.ash_action, widget)
      {:noreply, assign(socket, :widgets, read_widgets())}
    end
  end

  def handle_event("confirm", _params, socket) do
    %{action: action, widget: widget} = socket.assigns.confirming
    run(action.ash_action, widget)
    {:noreply, assign(socket, confirming: nil, widgets: read_widgets())}
  end

  defp run(:activate, %Widget{name: "Untraced" <> _rest} = widget) do
    {1, _rows} =
      Repo.update_all(
        from(w in "widgets", where: w.id == type(^widget.id, Ecto.UUID)),
        set: [active: true]
      )
  end

  defp run(:activate, widget) do
    widget |> Ash.Changeset.for_update(:activate, %{}) |> Ash.update!(authorize?: false)
  end

  defp run(:remove, widget) do
    widget |> Ash.Changeset.for_destroy(:remove, %{}) |> Ash.destroy!(authorize?: false)
  end

  defp read_widgets do
    Widget |> Ash.Query.for_read(:read) |> Ash.Query.sort(:name) |> Ash.read!(authorize?: false)
  end
end

defmodule AshBrowserTests.Fixture.BusyLive do
  @moduledoc false
  # A page that never settles: something on it stays busy.
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns), do: ~H(<div id="busy" aria-busy="true">Working…</div>)
end

defmodule AshBrowserTests.Fixture.WhoamiLive do
  @moduledoc false
  use Phoenix.LiveView

  @impl true
  def mount(_params, session, socket),
    do: {:ok, assign(socket, :user, session["user"] || "nobody")}

  @impl true
  def render(assigns), do: ~H(<p id="whoami">{@user}</p>)
end

defmodule AshBrowserTests.Fixture.PlainLive do
  @moduledoc false
  use Phoenix.LiveView

  @impl true
  def mount(params, _session, socket), do: {:ok, assign(socket, :id, params["id"] || "plain")}

  @impl true
  def render(assigns), do: ~H(<div id={@id}>Plain page</div>)
end

defmodule AshBrowserTests.Fixture.PageController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html]

  def boom(_conn, _params), do: raise("fixture 500")

  def ok(conn, _params), do: text(conn, "ok")
end

defmodule AshBrowserTests.Fixture.Router do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_root_layout, html: {AshBrowserTests.Fixture.Layouts, :root})
  end

  scope "/", AshBrowserTests.Fixture do
    pipe_through(:browser)

    live("/widgets", WidgetsLive)
    live("/journey/widgets", JourneyWidgetsLive)
    live("/busy", BusyLive)
    live("/whoami", WhoamiLive)
    live("/plain", PlainLive)
    live("/console-error", PlainLive)
    live("/page-error", PlainLive)
    live("/fetches-500", PlainLive)
    get("/boom", PageController, :boom)
    get("/ok", PageController, :ok)
  end
end

defmodule AshBrowserTests.Fixture.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :ash_browser_tests

  @session_options [
    store: :cookie,
    key: "_fixture",
    signing_salt: "fixturesalt",
    same_site: "Lax"
  ]

  def session_options, do: @session_options

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:user_agent, session: @session_options]]
  )

  plug(Phoenix.Ecto.SQL.Sandbox)
  plug(AshEnterprise.Telemetry.OtlpIngest)

  plug(Plug.Static, at: "/assets", from: Path.expand("static", __DIR__))

  plug(Plug.Static,
    at: "/vendor/phoenix",
    from: {:phoenix, "priv/static"},
    only: ~w(phoenix.min.js)
  )

  plug(Plug.Static,
    at: "/vendor/live_view",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.min.js)
  )

  plug(Plug.Static,
    at: "/vendor/telemetry",
    from: {:ash_enterprise_telemetry, "priv/js"},
    only: ~w(socket_tracing.js)
  )

  plug(Plug.Session, @session_options)
  plug(AshBrowserTests.Fixture.Router)
end
