defmodule AshEnterprise.Telemetry.TestLogExporter do
  @moduledoc false
  # Hands each exported log batch, encoded as the OTLP exporter encodes it, to the
  # process registered as `:ash_telemetry_test_logs`.

  def init(config), do: {:ok, config}

  def export({batch, config}, resource, _state) do
    case Process.whereis(:ash_telemetry_test_logs) do
      nil -> :ok
      pid -> send(pid, {:otlp_logs, :otel_otlp_logs.to_proto(batch, resource, config)})
    end

    :ok
  end

  def shutdown(_state), do: :ok
end

defmodule AshEnterprise.Telemetry.CaptureLogHandler do
  @moduledoc false
  # A logger handler that hands each event, after its filters, to a test process.

  def log(event, %{config: %{pid: pid}}), do: send(pid, {:log_event, event})
end

defmodule AshEnterprise.Telemetry.CrashFixtures do
  @moduledoc false

  def echo(value), do: value

  # Raises a FunctionClauseError whose frame carries `value`.
  def clause(value), do: only_never(value)

  defp only_never(%{"never" => true}), do: :ok
end

defmodule AshEnterprise.Telemetry.CrashServer do
  @moduledoc false
  use GenServer

  alias AshEnterprise.Telemetry.CrashFixtures

  def init(state), do: {:ok, state}

  def handle_cast({:crash, value}, state) do
    CrashFixtures.clause(value)
    {:noreply, state}
  end
end

defmodule AshEnterprise.Telemetry.QuietServer do
  @moduledoc false
  # No `handle_info/2`: GenServer's default logs every message it is sent.
  use GenServer

  def init(state), do: {:ok, state}
end

defmodule AshEnterprise.Telemetry.CrashStatem do
  @moduledoc false
  @behaviour :gen_statem

  alias AshEnterprise.Telemetry.CrashFixtures

  def callback_mode, do: :state_functions

  def init(data), do: {:ok, :idle, data}

  def idle(:cast, {:crash, value}, data) do
    :ok = CrashFixtures.echo({:error, value})
    {:keep_state, data}
  end
end

defmodule AshEnterprise.Telemetry.CrashWorker do
  @moduledoc false
  use GenServer, restart: :temporary

  def start_link(secret), do: GenServer.start_link(__MODULE__, secret)

  def init(secret), do: {:ok, secret}

  def handle_cast(:stop, secret), do: {:stop, {:bad_state, secret}, secret}
end

defmodule AshEnterprise.Telemetry.TestStrictLive do
  @moduledoc false
  # Handles one event and nothing else, so any other event has no matching clause.
  use Phoenix.LiveView

  def mount(_params, _session, socket),
    do: {:ok, assign(socket, api_secret: "strict-assign-secret")}

  def render(assigns) do
    ~H"""
    <p id="strict">strict</p>
    """
  end

  def handle_event("known", _params, socket), do: {:noreply, socket}
end
