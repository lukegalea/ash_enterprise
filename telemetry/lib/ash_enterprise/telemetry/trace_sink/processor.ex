defmodule AshEnterprise.Telemetry.TraceSink.Processor do
  @moduledoc """
  Feeds spans to `AshEnterprise.Telemetry.TraceSink` from the span processor chain.

  The SDK folds `on_end` as `Bool andalso P:on_end(Span, Config) =:= true`, so the first
  processor that returns anything else silently stops every processor after it.
  `otel_simple_processor` returns its call's reply, which is not `true`, so a simple
  processor in front of the OTLP batch processor means nothing reaches OTLP. This
  processor always returns `true`, whatever happens to the sink, and exports
  synchronously on the span-ending process, so a trace is readable as soon as its
  operation returns.

  List it before the batch processor; `AshEnterprise.Telemetry.processors/1` does.
  The batch processor can return `dropped` under overload, so it must come last.
  """

  @behaviour :otel_span_processor

  alias AshEnterprise.Telemetry.TraceSink

  require Record

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  @sampled 1

  @impl :otel_span_processor
  def on_start(_ctx, span_record, _config), do: span_record

  @impl :otel_span_processor
  def on_end(span_record, _config) do
    if Bitwise.band(span(span_record, :trace_flags), @sampled) == @sampled do
      _ = TraceSink.export([span_record])
    end

    true
  catch
    _kind, _reason -> true
  end

  @impl :otel_span_processor
  def force_flush(_config), do: :ok
end
