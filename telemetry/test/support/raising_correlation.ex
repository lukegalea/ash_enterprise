defmodule AshEnterprise.Telemetry.RaisingCorrelation do
  @moduledoc false
  @behaviour AshEnterprise.Telemetry.Correlation

  @impl true
  def current, do: raise("correlation unavailable")
  @impl true
  def put(_id), do: raise("correlation unavailable")
  @impl true
  def start_new, do: raise("correlation unavailable")
  @impl true
  def with_correlation(_id, _fun), do: raise("correlation unavailable")
end

defmodule AshEnterprise.Telemetry.CrashingServer do
  @moduledoc false
  use GenServer

  @impl true
  def init(arg), do: {:ok, arg}

  @impl true
  def handle_info(:crash, _state), do: raise("server crashed")
end

defmodule AshEnterprise.Telemetry.TestOtlpExporter do
  @moduledoc false
  @behaviour :otel_exporter_traces

  @impl true
  def init(_config), do: {:ok, []}

  @impl true
  def export(tid, _resource, _config) do
    case Process.whereis(:ash_telemetry_test_otlp) do
      nil -> :ok
      pid -> Enum.each(:ets.tab2list(tid), &send(pid, {:otlp_span, &1}))
    end

    :ok
  end

  @impl true
  def shutdown(_config), do: :ok
end
