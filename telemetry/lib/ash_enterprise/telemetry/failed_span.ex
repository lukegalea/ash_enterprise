defmodule AshEnterprise.Telemetry.FailedSpan do
  @moduledoc """
  Remembers, in the failing process, the span whose code just raised.

  A crash is logged after its span has closed and the context has been detached, so
  anything reading the current span at that point (`Sentry.LoggerHandler`, the log
  filter) finds none and the report cannot be joined to its trace. The exception
  handlers call `remember/0` while the span is still current.

  The memory is per process and expires after five seconds, so a process that
  survives cannot lend an old trace to a later, unrelated report.
  """

  @key {__MODULE__, :last}
  @ttl_ms 5_000

  @doc "Records the current span, if there is one. Never raises."
  @spec remember() :: :ok
  def remember do
    case OpenTelemetry.Tracer.current_span_ctx() |> OpenTelemetry.Span.hex_span_ctx() do
      %{otel_trace_id: _} = ids -> Process.put(@key, {now(), ids})
      _none -> nil
    end

    :ok
  catch
    _kind, _reason -> :ok
  end

  @doc "The remembered ids (`:otel_trace_id`, `:otel_span_id`), or an empty map."
  @spec current() :: map()
  def current do
    case Process.get(@key) do
      {at, ids} when is_integer(at) -> if now() - at <= @ttl_ms, do: ids, else: %{}
      _none -> %{}
    end
  end

  @doc "Whether this process has a span failure to report against."
  @spec recent?() :: boolean()
  def recent?, do: current() != %{}

  defp now, do: System.monotonic_time(:millisecond)
end
