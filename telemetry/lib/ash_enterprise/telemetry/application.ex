defmodule AshEnterprise.Telemetry.Application do
  @moduledoc false

  # The supervision tree is what makes the ingest and the sink safe to call from
  # request processes: every ETS table here is owned by one of these long-lived
  # children, never by the process that happened to touch it first. Each child
  # starts only when its feature is configured, so a host that configures
  # nothing pays for nothing.

  use Application

  alias AshEnterprise.Telemetry.BackgroundProbe
  alias AshEnterprise.Telemetry.OtlpIngest
  alias AshEnterprise.Telemetry.TraceSink

  @impl Application
  def start(_type, _args) do
    Supervisor.start_link(children(),
      strategy: :one_for_one,
      name: AshEnterprise.Telemetry.Supervisor
    )
  end

  defp children do
    sink() ++ ingest() ++ probe()
  end

  defp sink do
    if Application.get_env(:ash_enterprise_telemetry, :trace_sink?, false) do
      [TraceSink]
    else
      []
    end
  end

  defp ingest do
    if OtlpIngest.configured?(), do: [OtlpIngest.Supervisor], else: []
  end

  defp probe do
    case Application.get_env(:ash_enterprise_telemetry, :background_probe) do
      nil -> []
      false -> []
      opts when is_list(opts) -> [{BackgroundProbe, opts}]
    end
  end
end
