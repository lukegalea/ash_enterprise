defmodule AshEnterprise.Telemetry.TraceSinkTest do
  use ExUnit.Case, async: false

  alias AshEnterprise.Telemetry.TraceSink
  alias OpenTelemetry.Tracer

  import AshEnterprise.Telemetry.TraceHelpers

  require Record
  require OpenTelemetry.Tracer

  @span_fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")

  defp id(bytes), do: :crypto.strong_rand_bytes(bytes) |> :binary.decode_unsigned()

  defp hex(int, width),
    do: int |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")

  defp span_record(opts) do
    defaults = %{
      start_time: System.monotonic_time(),
      end_time: System.monotonic_time() + 1_000,
      attributes: %{}
    }

    values =
      @span_fields
      |> Map.new()
      |> Map.merge(defaults)
      |> Map.merge(Map.new(opts))
      |> Map.update!(:attributes, &:otel_attributes.new(&1, 128, :infinity))

    @span_fields
    |> Enum.map(fn {field, _} -> Map.fetch!(values, field) end)
    |> List.insert_at(0, :span)
    |> List.to_tuple()
  end

  defp otlp_payload(trace_hex, spans) do
    %{
      "resourceSpans" => [
        %{"scopeSpans" => [%{"spans" => Enum.map(spans, &Map.put(&1, "traceId", trace_hex))}]}
      ]
    }
  end

  defp otlp_span(span_hex, opts \\ []) do
    nanos = System.os_time(:nanosecond)

    %{
      "spanId" => span_hex,
      "name" => Keyword.get(opts, :name, "browser.span"),
      "startTimeUnixNano" => to_string(nanos),
      "endTimeUnixNano" => to_string(nanos + 1_000_000),
      "attributes" => Keyword.get(opts, :attributes, [])
    }
    |> then(&if opts[:parent], do: Map.put(&1, "parentSpanId", opts[:parent]), else: &1)
  end

  describe "completion" do
    test "a parentless span completes the trace" do
      trace_id = id(16)

      :ok =
        TraceSink.export([
          span_record(trace_id: trace_id, span_id: id(8), parent_span_id: :undefined)
        ])

      assert TraceSink.trace(trace_id)
    end

    test "a span with a remote parent completes the trace" do
      trace_id = id(16)

      :ok =
        TraceSink.export([
          span_record(
            trace_id: trace_id,
            span_id: id(8),
            parent_span_id: id(8),
            attributes: %{"ash.parent_remote" => true}
          )
        ])

      assert TraceSink.trace(trace_id)
    end

    test "a span whose parent is local does not complete the trace" do
      trace_id = id(16)

      :ok =
        TraceSink.export([span_record(trace_id: trace_id, span_id: id(8), parent_span_id: id(8))])

      assert TraceSink.trace(trace_id) == nil
    end

    test "a real remote-parented span and its local child complete once, with both spans" do
      key = test_key!()
      tp = traceparent()

      ctx =
        :otel_propagator_text_map.extract_to(OpenTelemetry.Ctx.new(), [{"traceparent", tp.header}])

      token = OpenTelemetry.Ctx.attach(ctx)

      Tracer.with_span "server.root" do
        Tracer.with_span "server.child" do
          assert TraceSink.trace(tp.trace_id) == nil
        end

        assert TraceSink.trace(tp.trace_id) == nil
      end

      OpenTelemetry.Ctx.detach(token)

      trace = TraceSink.trace(tp.trace_id)
      assert trace.root.name == "server.root"
      assert length(spans(key)) == 2
    end
  end

  describe "late spans" do
    test "a span arriving after completion is appended" do
      trace_id = id(16)
      root_id = id(8)

      :ok =
        TraceSink.export([
          span_record(
            trace_id: trace_id,
            span_id: root_id,
            parent_span_id: :undefined,
            name: "root"
          )
        ])

      assert length(TraceSink.trace(trace_id).spans) == 1

      :ok =
        TraceSink.export([
          span_record(trace_id: trace_id, span_id: id(8), parent_span_id: root_id, name: "late")
        ])

      trace = TraceSink.trace(trace_id)
      assert length(trace.spans) == 2
      assert Enum.any?(trace.spans, &(&1.name == "late"))
    end

    test "a browser root arriving after the server span takes over as the root" do
      trace_hex = hex(id(16), 32)
      browser_hex = hex(id(8), 16)

      :ok =
        TraceSink.export([
          span_record(
            trace_id: String.to_integer(trace_hex, 16),
            span_id: id(8),
            parent_span_id: String.to_integer(browser_hex, 16),
            name: "server",
            attributes: %{"ash.parent_remote" => true}
          )
        ])

      assert TraceSink.trace(trace_hex).root.name == "server"

      :ok =
        TraceSink.ingest_otlp(
          otlp_payload(trace_hex, [otlp_span(browser_hex, name: "/page Save")])
        )

      trace = TraceSink.trace(trace_hex)
      assert trace.root.name == "/page Save"
      assert length(trace.spans) == 2
    end
  end

  describe "duplicates" do
    test "re-exporting a span keeps one copy and one count" do
      trace_id = id(16)

      span =
        span_record(trace_id: trace_id, span_id: id(8), parent_span_id: :undefined, name: "once")

      :ok = TraceSink.export([span])
      before = TraceSink.stats()
      :ok = TraceSink.export([span])

      assert length(TraceSink.trace(trace_id).spans) == 1
      assert TraceSink.stats().spans == before.spans
    end

    test "the first copy wins" do
      trace_id = id(16)
      span_id = id(8)

      :ok =
        TraceSink.export([
          span_record(
            trace_id: trace_id,
            span_id: span_id,
            parent_span_id: :undefined,
            name: "first"
          )
        ])

      :ok =
        TraceSink.export([
          span_record(
            trace_id: trace_id,
            span_id: span_id,
            parent_span_id: :undefined,
            name: "second"
          )
        ])

      assert [%{name: "first"}] = TraceSink.trace(trace_id).spans
    end
  end

  describe "links" do
    test "links are kept, so a job can name its producer" do
      trace_id = id(16)
      linked_trace = id(16)
      linked_span = id(8)

      link = OpenTelemetry.link(:otel_tracer.from_remote_span(linked_trace, linked_span, 1))
      links = :otel_links.new([link], 128, 128, :infinity)

      :ok =
        TraceSink.export([
          span_record(
            trace_id: trace_id,
            span_id: id(8),
            parent_span_id: :undefined,
            links: links
          )
        ])

      assert [%{trace_id: ^linked_trace, span_id: ^linked_span}] =
               hd(TraceSink.trace(trace_id).spans).links
    end

    test "a real linked span round-trips" do
      key = test_key!()
      other = Tracer.start_span("link.target")

      Tracer.with_span "linker", %{links: [OpenTelemetry.link(other)]} do
        :ok
      end

      OpenTelemetry.Span.end_span(other)

      target_id = OpenTelemetry.Span.span_id(other)
      assert [%{span_id: ^target_id}] = span_named(key, "linker").links
    end
  end

  describe "OTLP JSON" do
    test "converts names, ids, events and attributes" do
      trace_hex = hex(id(16), 32)
      span_hex = hex(id(8), 16)
      nanos = System.os_time(:nanosecond)

      span =
        otlp_span(span_hex,
          name: "browser.click",
          attributes: [%{"key" => "ui.page.path", "value" => %{"stringValue" => "/widgets"}}]
        )
        |> Map.put("events", [
          %{"name" => "exception", "timeUnixNano" => to_string(nanos), "attributes" => []}
        ])
        |> Map.put("status", %{"code" => 2, "message" => "failed"})

      :ok = TraceSink.ingest_otlp(otlp_payload(trace_hex, [span]))

      trace = TraceSink.trace(trace_hex)
      assert trace.root.name == "browser.click"
      assert attr(trace.root, "ui.page.path") == "/widgets"
      assert [%{name: "exception"}] = trace.root.events
      assert trace.error? == true
      assert trace.root.parent_span_id in [0, :undefined, nil]
    end

    test "duplicate delivery of a browser span is counted once" do
      trace_hex = hex(id(16), 32)
      payload = otlp_payload(trace_hex, [otlp_span(hex(id(8), 16))])

      :ok = TraceSink.ingest_otlp(payload)
      before = TraceSink.stats()
      :ok = TraceSink.ingest_otlp(payload)

      assert length(TraceSink.trace(trace_hex).spans) == 1
      assert TraceSink.stats().spans == before.spans
    end

    test "a false boolean attribute is kept" do
      trace_hex = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      span_hex = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

      span =
        otlp_span(span_hex, name: "bool.span")
        |> Map.put("attributes", [
          %{"key" => "flag.off", "value" => %{"boolValue" => false}},
          %{"key" => "flag.on", "value" => %{"boolValue" => true}}
        ])

      :ok = TraceSink.ingest_otlp(otlp_payload(trace_hex, [span]))

      attributes = TraceSink.trace(trace_hex).root.attributes
      assert Map.fetch(attributes, "flag.off") == {:ok, false}
      assert Map.fetch(attributes, "flag.on") == {:ok, true}
    end

    test "malformed input is ignored" do
      assert TraceSink.ingest_otlp(%{"resourceSpans" => "nope"}) == :ok
      assert TraceSink.ingest_otlp(%{}) == :ok

      assert TraceSink.ingest_otlp(%{
               "resourceSpans" => [%{"scopeSpans" => [%{"spans" => [%{"spanId" => 1}]}]}]
             }) ==
               :ok
    end
  end

  describe "lookup by test key" do
    test "finds a trace by its key, and not another test's" do
      key = test_key!()

      Tracer.with_span "keyed" do
        :ok
      end

      assert [%{root: %{name: "keyed"}}] = TraceSink.by_test_key(key)
      assert TraceSink.by_test_key("no-such-key") == []
    end
  end

  test "the ring size is configurable for tests" do
    assert Application.get_env(:ash_enterprise_telemetry, :trace_sink)[:ring_size] == 5_000
    assert TraceSink.stats().ring_size >= 5_000
  end
end
