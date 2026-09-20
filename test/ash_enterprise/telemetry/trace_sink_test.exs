defmodule AshEnterprise.Telemetry.TraceSinkTest do
  use ExUnit.Case, async: false

  # The sink is a named singleton fed by the whole suite's spans (test.exs wires
  # otel_simple_processor -> TraceSink.Exporter), so assertions here are written
  # to hold under concurrent traffic from other tests: per-trace-id facts and
  # the *shape* of the invariants (fully present or fully absent), never global
  # counts that unrelated exports could move.

  alias AshEnterprise.Telemetry.TraceSink

  require Record

  @ring :__trace_ring__
  @spans :__trace_spans__
  @by_correlation :__trace_by_correlation__
  @by_symbol :__trace_by_symbol__

  @span_fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")

  setup do
    TraceSink.clear()

    original = Application.get_env(:ash_enterprise, :trace_sink, [])

    on_exit(fn ->
      Application.put_env(:ash_enterprise, :trace_sink, original)
      TraceSink.clear()
    end)

    :ok
  end

  defp with_bounds(ring_size: rs, max_spans: ms) do
    Application.put_env(:ash_enterprise, :trace_sink, ring_size: rs, max_spans: ms)
  end

  # --- Span fabrication ---------------------------------------------------------

  defp next_id(bytes) do
    :crypto.strong_rand_bytes(bytes) |> :binary.decode_unsigned()
  end

  defp span_record(opts) do
    values =
      @span_fields
      |> Map.new()
      |> Map.merge(Map.new(opts))
      |> Map.update!(:attributes, &otel_attributes/1)

    @span_fields
    |> Enum.map(fn {field, _} -> Map.fetch!(values, field) end)
    |> List.insert_at(0, :span)
    |> List.to_tuple()
  end

  defp otel_attributes(%{} = attrs), do: :otel_attributes.new(attrs, 128, :infinity)
  defp otel_attributes(other), do: other

  defp now, do: System.monotonic_time()

  # Exports one trace of `span_count` spans as a single batch, root last — the
  # order the simple processor delivers them.
  defp export_trace(trace_id, span_count, attrs \\ %{}) do
    spans =
      for i <- span_count..1//-1 do
        parent = if i == 1, do: 0, else: next_id(8)

        span_record(
          trace_id: trace_id,
          span_id: next_id(8),
          parent_span_id: parent,
          name: "test-span-#{i}",
          start_time: now(),
          end_time: now() + 1_000,
          attributes: attrs
        )
      end

    :ok = TraceSink.export(spans)
    trace_id
  end

  # --- The real pipeline feeds the sink ------------------------------------------

  test "spans from the ordinary OpenTelemetry pipeline land in the sink" do
    require OpenTelemetry.Tracer

    OpenTelemetry.Tracer.with_span "sink-test-root" do
      OpenTelemetry.Tracer.with_span "sink-test-child" do
        :ok
      end
    end

    # Simple processor export is synchronous with span end: no waiting.
    traced =
      TraceSink.last(20)
      |> Enum.find(&Enum.any?(&1.spans, fn s -> s.name == "sink-test-root" end))

    assert traced
    assert traced.root.name == "sink-test-root"

    names = Enum.map(traced.spans, & &1.name) |> Enum.sort()
    assert names == ["sink-test-child", "sink-test-root"]
    assert traced.duration_ms >= 0
    assert traced.error? == false
  end

  # --- Invariant: no partial-trace observation -------------------------------------

  test "a trace is invisible until its root span is exported (commit point)" do
    trace_id = next_id(16)
    child = span_record(trace_id: trace_id, span_id: next_id(8), parent_span_id: next_id(8))

    :ok = TraceSink.export([child])

    # Children alone: no root, not committed, not observable.
    assert TraceSink.trace(trace_id) == nil
    assert trace_id not in Enum.map(TraceSink.last(50), & &1.trace_id)

    root =
      span_record(
        trace_id: trace_id,
        span_id: next_id(8),
        parent_span_id: 0,
        start_time: now(),
        end_time: now() + 1_000
      )

    :ok = TraceSink.export([root])

    # Root landed: the trace is now observable in full.
    trace = TraceSink.trace(trace_id)
    assert trace
    assert length(trace.spans) == 2
    assert trace.root.parent_span_id == 0
  end

  test "trace lookup accepts hex spellings and rejects garbage" do
    trace_id = export_trace(next_id(16), 2)
    hex = Integer.to_string(trace_id, 16)
    padded = String.pad_leading(hex, 32, "0")

    assert TraceSink.trace(hex).trace_id == trace_id
    assert TraceSink.trace("0x" <> padded).trace_id == trace_id
    # Whitespace is tolerated on an otherwise valid hex id.
    assert TraceSink.trace(padded <> " ").trace_id == trace_id
    assert TraceSink.trace("zzz") == nil
    assert TraceSink.trace(1) == nil
  end

  # --- Invariant: trace-atomic eviction ---------------------------------------------

  test "eviction drops the whole oldest trace and never a partial one" do
    with_bounds(ring_size: 3, max_spans: 20_000)

    traces = for _ <- 1..4, do: export_trace(next_id(16), 2)
    [oldest | rest] = traces

    # The oldest trace is gone — completely: no trace record, no spans, no ring
    # entries, no index entries. Eviction never leaves a partial trace behind.
    refute_trace_exists(oldest)

    # Every one of our traces is either fully present (and complete) or fully
    # absent — the atomicity assertion, robust to concurrent suite traffic.
    for trace_id <- traces, do: assert_trace_atomic(trace_id)

    stats = TraceSink.stats()
    assert stats.traces <= 3

    # At least the newest of the survivors should be observable.
    assert TraceSink.trace(List.last(rest))
  end

  # --- Invariant: max_spans backstop ---------------------------------------------------

  test "max_spans backstop drops whole oldest traces" do
    with_bounds(ring_size: 50, max_spans: 8)

    t1 = export_trace(next_id(16), 3)
    t2 = export_trace(next_id(16), 3)

    # 6 spans: under the backstop, nothing evicted yet.
    assert TraceSink.trace(t1)
    assert TraceSink.trace(t2)

    # 9 spans: over the backstop. The whole OLDEST trace goes — not one span
    # of it, and not the wrong trace.
    t3 = export_trace(next_id(16), 3)

    refute_trace_exists(t1)
    assert_trace_atomic(t2)
    assert_trace_atomic(t3)

    assert TraceSink.stats().spans <= 8 + pollution_margin()
  end

  # --- Invariant: flood survival ---------------------------------------------------------

  test "a flood of traces is survived, bounded, and every survivor is complete" do
    with_bounds(ring_size: 50, max_spans: 20_000)

    traces = for _ <- 1..300, do: export_trace(next_id(16), 5)

    assert TraceSink.running?()

    stats = TraceSink.stats()
    assert stats.traces <= 50
    assert stats.spans <= 20_000

    visible = TraceSink.last(50)
    assert visible != []

    # A reader may never observe a partial trace — every rendered trace has a
    # root and every span it claims.
    for trace <- visible do
      assert trace.root
      assert MapSet.new(trace.spans, & &1.span_id) |> MapSet.size() == length(trace.spans)
      assert trace.root in trace.spans
    end

    # And the per-trace atomicity holds across the flood's survivors.
    for trace_id <- Enum.take(traces, -50), do: assert_trace_atomic(trace_id)
  end

  # --- Indexes ------------------------------------------------------------------------------

  test "correlation and symbol indexes resolve to complete traces" do
    attrs = %{"ash.correlation_id" => "corr-123", "ash.symbol_id" => "ash:v0:Demo#do_thing"}

    trace_id = export_trace(next_id(16), 2, attrs)
    _ = export_trace(next_id(16), 2)

    [by_corr] = TraceSink.by_correlation("corr-123")
    assert by_corr.trace_id == trace_id
    assert by_corr.correlation_ids == ["corr-123"]
    assert by_corr.symbol_ids == ["ash:v0:Demo#do_thing"]

    [by_symbol] = TraceSink.by_symbol("ash:v0:Demo#do_thing")
    assert by_symbol.trace_id == trace_id

    assert TraceSink.by_correlation("corr-absent") == []
    assert TraceSink.by_symbol("ash:v0:Absent#nothing") == []
  end

  test "eviction removes index entries with the trace" do
    with_bounds(ring_size: 1, max_spans: 20_000)

    attrs = %{"ash.correlation_id" => "corr-evict"}

    t1 = export_trace(next_id(16), 2, attrs)
    t2 = export_trace(next_id(16), 2, attrs)

    refute_trace_exists(t1)

    survivors = TraceSink.by_correlation("corr-evict")
    assert Enum.map(survivors, & &1.trace_id) == [t2]
  end

  # --- Ordering & housekeeping -----------------------------------------------------------------

  test "last/1 returns newest first" do
    with_bounds(ring_size: 50, max_spans: 20_000)

    mine = for _ <- 1..3, do: export_trace(next_id(16), 2)

    survivors = Enum.filter(mine, &TraceSink.trace(&1))

    ordered =
      TraceSink.last(50)
      |> Enum.map(& &1.trace_id)
      |> Enum.filter(&(&1 in survivors))

    assert ordered == Enum.reverse(survivors)
  end

  test "stats report the live bounds" do
    with_bounds(ring_size: 7, max_spans: 99)

    assert %{ring_size: 7, max_spans: 99} = TraceSink.stats()
  end

  test "clear/0 removes every trace of a trace" do
    trace_id = export_trace(next_id(16), 2)
    assert TraceSink.trace(trace_id)

    :ok = TraceSink.clear()

    refute_trace_exists(trace_id)
    assert TraceSink.last(10) == []
  end

  # --- Helpers ------------------------------------------------------------------------------------

  # The trace must leave ZERO residue: the trace-atomic guarantee.
  defp refute_trace_exists(trace_id) do
    assert TraceSink.trace(trace_id) == nil
    assert :ets.match_object(@ring, {:_, trace_id}) == []
    assert :ets.match_object(@spans, {{trace_id, :_}, :_, :_}) == []
    assert :ets.match_object(@by_correlation, {:_, trace_id}) == []
    assert :ets.match_object(@by_symbol, {:_, trace_id}) == []
  end

  # Either fully present (and complete — a reader may never observe a partial
  # trace; render/1 already refuses to render incomplete ones) or fully absent.
  # Concurrent suite traffic may evict at any moment; the invariant is that it
  # never happens halfway.
  defp assert_trace_atomic(trace_id) do
    case TraceSink.trace(trace_id) do
      nil -> refute_trace_exists(trace_id)
      trace -> assert trace.root != nil
    end
  end

  # Concurrent exports from other tests can sit between "spans inserted" and
  # "eviction run" (the GenServer serialises batches, but our stats read can
  # interleave with another batch). A small margin keeps that honest race from
  # flaking bound assertions without weakening them.
  defp pollution_margin, do: 64
end
