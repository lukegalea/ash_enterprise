defmodule AshEnterprise.Bpmn.Telemetry do
  @moduledoc """
  How far behind the trigger sweep is, and how long an event waits to start its process.

  | Event | Measurement | Metadata |
  |---|---|---|
  | `[:ash_enterprise, :bpmn, :sweep]` | `lag`: the tenant's newest audit sequence minus the sweep cursor after the batch | `tenant` |
  | `[:ash_enterprise, :bpmn, :dispatch, :start]` | `latency`: from the event happening to the dispatch that started its process, native time units | `tenant`, `kind` |

  The metrics are declared in `AshEnterpriseWeb.Telemetry.bpmn_metrics/0`.

  ## Lag

  `ash_bpmn` reports each sweep batch (`[:ash_bpmn, :triggers, :sweep]`, with the position the
  cursor reached). The handler attached here reads the tenant's newest sequence from
  `AshEnterprise.Audit.EventSource` (one indexed read) and reports the
  difference: zero when the sweep is caught up, growing when a tenant writes faster than its
  one sweeper reads. The handler runs in the sweep's process after the batch has committed.
  A handler that raised would be detached by `:telemetry`, so a failure here is logged and
  the lag for that batch is not reported.

  ## Dispatch-to-start latency

  Reported by `AshEnterprise.Bpmn.Dispatch.ReportLatency` as a dispatch that started a process
  is written: the time since the event's `occurred_at`, which includes the cron interval,
  the sweep's lag and the funnel. A re-drive's start reports it too, so a re-driven failure
  shows the hours it waited.
  """

  require Logger

  @handler "ash-enterprise-bpmn-sweep-lag"

  @doc "Attaches the sweep-lag handler. Idempotent."
  @spec attach() :: :ok
  def attach do
    _ = :telemetry.detach(@handler)

    :ok =
      :telemetry.attach(@handler, [:ash_bpmn, :triggers, :sweep], &__MODULE__.handle_sweep/4, nil)
  end

  @doc false
  def handle_sweep(_event, _measurements, %{tenant: tenant, last_sequence: position}, _config)
      when is_integer(position) do
    newest = AshEnterprise.Audit.EventSource.latest_sequence(tenant)
    sweep_lag(tenant, max(newest - position, 0))
  rescue
    e ->
      Logger.warning(
        "bpmn sweep lag not reported for #{inspect(tenant)}: #{Exception.message(e)}"
      )
  end

  def handle_sweep(_event, _measurements, _metadata, _config), do: :ok

  @doc "Reports `lag` events between `tenant`'s newest audit sequence and its sweep cursor."
  @spec sweep_lag(term(), non_neg_integer()) :: :ok
  def sweep_lag(tenant, lag),
    do: :telemetry.execute([:ash_enterprise, :bpmn, :sweep], %{lag: lag}, %{tenant: tenant})

  @doc "Reports the time from an event happening to the dispatch that started its process."
  @spec dispatch_started(term(), atom(), DateTime.t()) :: :ok
  def dispatch_started(tenant, kind, %DateTime{} = occurred_at) do
    micros = max(DateTime.diff(DateTime.utc_now(), occurred_at, :microsecond), 0)

    :telemetry.execute(
      [:ash_enterprise, :bpmn, :dispatch, :start],
      %{latency: System.convert_time_unit(micros, :microsecond, :native)},
      %{tenant: tenant, kind: kind}
    )
  end

  def dispatch_started(_tenant, _kind, _occurred_at), do: :ok
end
