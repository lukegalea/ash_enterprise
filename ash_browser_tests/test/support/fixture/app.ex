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
    data_layer: AshPostgres.DataLayer

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
