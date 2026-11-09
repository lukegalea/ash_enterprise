defmodule AshEnterprise.Telemetry.Logging do
  @moduledoc """
  Puts trace ids on log events and wires the OTLP log handler.

  `add_trace_filter/0` adds a primary logger filter that copies the current span's
  `otel_trace_id`, `otel_span_id` and `otel_trace_flags`, and the correlation id, into
  each event's metadata. Filters run in the logging process, so the context is the
  one that is actually current. The OTLP log handler reads the same keys, which is
  what joins a log line to its trace.

  `add_otlp_handler/1` adds the `opentelemetry_experimental` handler, with HTTP
  protobuf as the exporter default (the upstream default of gRPC needs a gRPC
  client this package does not carry).

  Logs and metrics take their resource attributes from the `opentelemetry_experimental`
  application's config, not from `opentelemetry`'s, so a host that sets `service.name`
  for traces sets it there as well.
  """

  alias AshEnterprise.Telemetry.FailedSpan
  alias AshEnterprise.Telemetry.Settings

  @filter_id :ash_enterprise_telemetry_trace_context
  @handler_id :ash_enterprise_telemetry_otlp_logs

  @doc "Adds the primary trace-context filter. Idempotent."
  @spec add_trace_filter() :: :ok
  def add_trace_filter do
    case :logger.add_primary_filter(@filter_id, {&__MODULE__.filter/2, []}) do
      :ok -> :ok
      {:error, {:already_exist, _id}} -> :ok
    end
  end

  @doc "Removes the primary trace-context filter."
  @spec remove_trace_filter() :: :ok | {:error, term()}
  def remove_trace_filter, do: :logger.remove_primary_filter(@filter_id)

  @doc false
  def filter(%{meta: meta} = event, _extra) do
    %{event | meta: Map.merge(meta, trace_metadata())}
  catch
    _kind, _reason -> :ignore
  end

  def filter(_event, _extra), do: :ignore

  defp trace_metadata do
    span =
      case OpenTelemetry.Tracer.current_span_ctx() |> OpenTelemetry.Span.hex_span_ctx() do
        empty when map_size(empty) == 0 -> FailedSpan.current()
        live -> live
      end

    case correlation() do
      nil -> span
      id -> Map.put(span, :correlation_id, id)
    end
  end

  defp correlation do
    case Settings.correlation().current() do
      id when is_binary(id) -> id
      _other -> nil
    end
  catch
    _kind, _reason -> nil
  end

  @doc """
  Adds the OTLP log handler. Accepts handler `:level` (default `:info`) and
  `:exporter` (default `{:otel_exporter_logs_otlp, %{protocol: :http_protobuf}}`) and
  `:scheduled_delay_ms` (default 1000).

  The log and metric exporters read their endpoint from the
  `:opentelemetry_experimental` application (`otlp_endpoint`), not from
  `:opentelemetry_exporter`. Setting `OTEL_EXPORTER_OTLP_ENDPOINT` covers traces,
  logs and metrics at once.
  """
  @spec add_otlp_handler(keyword()) :: :ok | {:error, term()}
  def add_otlp_handler(opts \\ []) do
    exporter =
      Keyword.get(opts, :exporter, {:otel_exporter_logs_otlp, %{protocol: :http_protobuf}})

    # `otel_log_handler` reads these from the top level of the handler config.
    config = %{
      level: Keyword.get(opts, :level, :info),
      exporter: exporter,
      scheduled_delay_ms: Keyword.get(opts, :scheduled_delay_ms, 1_000)
    }

    case :logger.add_handler(@handler_id, :otel_log_handler, config) do
      :ok -> :ok
      {:error, {:already_exist, _id}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
