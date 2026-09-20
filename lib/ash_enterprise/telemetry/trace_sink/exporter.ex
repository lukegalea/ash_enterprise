defmodule AshEnterprise.Telemetry.TraceSink.Exporter do
  @moduledoc """
  The bridge from the OpenTelemetry SDK to the dev-loop sink.

  Implements the `:otel_exporter_traces` behaviour (`init/1`, `export/3`,
  `shutdown/1`) so it can be named as an exporter anywhere the SDK takes one.
  The SDK hands us an ETS table of `#span{}` records and the resource; we copy
  the records out and hand them to `AshEnterprise.Telemetry.TraceSink`.

  The export runs while `otel_simple_processor` blocks the span-ending
  process, which is the property that makes the sink's read-after-write
  guarantee: the moment an Ash action returns, its spans (root included) are
  queryable. Exceptions are swallowed and reported as `:failed_not_retryable`
  — a dev-loop sink must never take the traced operation down with it.

  Wired in `config/dev.exs` / `config/test.exs`:

      config :opentelemetry,
        span_processor: :simple,
        traces_exporter: {AshEnterprise.Telemetry.TraceSink.Exporter, []}

  (The SDK merges `traces_exporter` into the processor's `exporter` option —
  and a user-set `traces_exporter` wins over processor opts, so this is the
  spelling the merge rules in `otel_configuration.erl` actually honour.)
  """

  @behaviour :otel_exporter_traces

  require Logger

  @impl :otel_exporter_traces
  def init(_config), do: {:ok, []}

  @impl :otel_exporter_traces
  def export(spans_tid, _resource, _config) do
    spans = :ets.tab2list(spans_tid)

    case AshEnterprise.Telemetry.TraceSink.export(spans) do
      :ok -> :ok
      # Sink not started (prod, or a test env that turned it off): report and
      # drop. There is no sink → backend backfill, ever.
      {:error, :not_running} -> :failed_not_retryable
    end
  rescue
    # Never let the sink take the traced operation down with it.
    exception ->
      Logger.warning(
        "TraceSink.Exporter dropped a span batch: " <> Exception.format(:error, exception)
      )

      :failed_not_retryable
  end

  @impl :otel_exporter_traces
  def shutdown(_state), do: :ok
end
