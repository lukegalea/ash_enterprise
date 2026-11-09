defmodule AshEnterprise.Telemetry.TraceHelpers do
  @moduledoc false

  alias AshEnterprise.Telemetry.TestKey
  alias AshEnterprise.Telemetry.TraceSink

  @doc "Sets a fresh per-test key on this process and returns it."
  def test_key! do
    key = "key-#{System.unique_integer([:positive])}"
    TestKey.put(key)
    key
  end

  @doc "All spans of the complete traces carrying `key`."
  def spans(key) do
    key
    |> TraceSink.by_test_key()
    |> Enum.flat_map(& &1.spans)
  end

  def span_named(key, name) do
    Enum.find(spans(key), &(&1.name == name))
  end

  def span_named_ending(key, suffix) do
    Enum.find(spans(key), &String.ends_with?(&1.name, suffix))
  end

  def attr(span, key),
    do: Map.get(span.attributes, key) || Map.get(span.attributes, to_string(key))

  @doc "A valid W3C traceparent with random ids and the given flags."
  def traceparent(flags \\ "01") do
    trace = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    span = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    %{
      header: "00-#{trace}-#{span}-#{flags}",
      trace_id: String.to_integer(trace, 16),
      span_id: String.to_integer(span, 16),
      hex_trace: trace,
      hex_span: span
    }
  end

  @doc "Polls until `fun` returns truthy, failing the test after `timeout`."
  def eventually(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _falsey ->
        if System.monotonic_time(:millisecond) > deadline do
          raise ExUnit.AssertionError, message: "condition not met in time"
        end

        Process.sleep(10)
        do_eventually(fun, deadline)
    end
  end
end
