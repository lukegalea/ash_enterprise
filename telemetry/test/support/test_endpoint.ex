defmodule AshEnterprise.Telemetry.TestEventAttributes do
  @moduledoc false

  def resolve("boom", _params, _socket), do: raise("resolver failure")

  def resolve("named", _params, _socket),
    do: %{"ui.action.name" => "activate", "ui.action.resource" => "Widget"}

  def resolve("forge", _params, _socket),
    do: %{"ash.correlation_id" => "forged", "ui.action.name" => "x"}

  def resolve(event, params, socket) do
    AshEnterprise.Telemetry.A2uiEventAttributes.resolve(event, params, socket)
  end
end

defmodule AshEnterprise.Telemetry.TestLive do
  @moduledoc false
  use Phoenix.LiveView

  require OpenTelemetry.Tracer

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :value, "none")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <p id="value">{@value}</p>
    """
  end

  @impl true
  def handle_event("raise", _params, _socket), do: raise("boom in handle_event")

  def handle_event("trace", _params, socket) do
    OpenTelemetry.Tracer.with_span "inside.event" do
      {:noreply, assign(socket, :value, "traced")}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}
end

defmodule AshEnterprise.Telemetry.TestRouter do
  @moduledoc false
  use Phoenix.Router, helpers: false
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
  end

  scope "/" do
    pipe_through(:browser)
    live("/live", AshEnterprise.Telemetry.TestLive)
  end
end

defmodule AshEnterprise.Telemetry.TestEndpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :ash_enterprise_telemetry

  @session_options [store: :cookie, key: "_t", signing_salt: "telemetrytest"]
  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Session, @session_options)
  plug(AshEnterprise.Telemetry.TestRouter)
end
