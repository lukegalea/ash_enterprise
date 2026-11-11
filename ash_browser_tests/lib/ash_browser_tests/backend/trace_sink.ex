defmodule AshBrowserTests.Backend.TraceSink do
  @moduledoc """
  Reads spans from `AshEnterprise.Telemetry.TraceSink`, the in-VM ring.

  A trace is included once it carries the test key. Inside it, spans stamped with a
  different key are dropped, so one test can never see another's work, and spans
  with no key (browser spans, which the server may not stamp) are kept.

  The sink's default ring is small. A browser suite raises it:

      config :ash_enterprise_telemetry, :trace_sink, ring_size: 5_000, max_spans: 200_000
  """

  @behaviour AshBrowserTests.Backend

  alias AshBrowserTests.Span
  alias AshBrowserTests.TestKey
  alias AshEnterprise.Telemetry.TraceSink

  @compile {:no_warn_undefined, AshEnterprise.Telemetry.TraceSink}

  @impl true
  def spans_for(key, _opts) do
    if Code.ensure_loaded?(TraceSink) and TraceSink.running?() do
      {:ok, key |> traces() |> Enum.flat_map(&spans_of/1) |> Enum.filter(&same_key?(&1, key))}
    else
      {:error, :trace_sink_not_running}
    end
  end

  defp traces({:trace_id, hex}), do: hex |> TraceSink.trace() |> List.wrap()
  defp traces({:correlation_id, id}), do: TraceSink.by_correlation(id)
  defp traces(key) when is_binary(key), do: TraceSink.by_test_key(key)

  defp spans_of(%{spans: spans}), do: Enum.map(spans, &normalize/1)

  defp same_key?(_span, {_selector, _value}), do: true

  defp same_key?(%Span{attributes: attributes}, key) do
    case Map.get(attributes, TestKey.attribute()) do
      nil -> true
      ^key -> true
      _other -> false
    end
  end

  @doc false
  def normalize(span) do
    %Span{
      trace_id: Span.hex(span.trace_id, 32),
      span_id: Span.hex(span.span_id, 16),
      parent_span_id: Span.hex(span[:parent_span_id], 16),
      name: span.name,
      kind: span[:kind] || :internal,
      status: span[:status_code] || :unset,
      status_message: span[:status_message],
      start_ns: span[:start_time],
      end_ns: span[:end_time],
      attributes: stringify(span[:attributes] || %{}),
      events: Enum.map(span[:events] || [], &event/1),
      links: Enum.map(span[:links] || [], &link/1),
      source: :trace_sink
    }
  end

  defp event(event), do: %{name: event.name, attributes: stringify(event.attributes)}

  defp link(link) do
    %{trace_id: Span.hex(link.trace_id, 32), span_id: Span.hex(link.span_id, 16)}
  end

  # Atom attribute values are strings once exported; matching real backends, they
  # are strings here too.
  defp stringify(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value(value)} end)
  end

  defp value(value) when is_atom(value) and value not in [nil, true, false], do: to_string(value)
  defp value(value), do: value
end
