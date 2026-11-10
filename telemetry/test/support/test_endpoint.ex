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
    {:ok, assign(socket, value: "none", api_secret: "assign-secret-value")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <p id="value">{@value}</p>
    """
  end

  @impl true
  def handle_event("raise", _params, _socket), do: raise("boom in handle_event")

  def handle_event("clause", params, socket), do: only_never(params, socket)

  def handle_event("match", %{"password" => password}, socket) do
    :ok = apply(__MODULE__, :echo, [{:error, password}])
    {:noreply, socket}
  end

  def handle_event("trace", _params, socket) do
    OpenTelemetry.Tracer.with_span "inside.event" do
      {:noreply, assign(socket, :value, "traced")}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  def echo(value), do: value

  defp only_never(%{"never" => true}, socket), do: {:noreply, socket}
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

defmodule AshEnterprise.Telemetry.BanditProbePlug do
  @moduledoc false
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{request_path: "/clause" <> _} = conn, _opts) do
    only_never(apply(__MODULE__, :echo, ["plug-arg-secret"]))
    send_resp(conn, 200, "")
  end

  def call(%{request_path: "/match" <> _} = conn, _opts) do
    :ok = apply(__MODULE__, :echo, [{:error, "plug-match-secret"}])
    send_resp(conn, 200, "")
  end

  def call(conn, _opts) do
    span = OpenTelemetry.Tracer.current_span_ctx()

    body =
      Jason.encode!(%{
        trace_id: span |> OpenTelemetry.Span.trace_id() |> hex(),
        recording: OpenTelemetry.Span.is_recording(span),
        baggage: OpenTelemetry.Baggage.get_all() |> Map.keys() |> Enum.map(&to_string/1)
      })

    send_resp(conn, 200, body)
  end

  def echo(value), do: value

  defp only_never(:never), do: :ok

  defp hex(trace_id),
    do: trace_id |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(32, "0")
end
