defmodule AshEnterprise.Telemetry.LoggingTest do
  use ExUnit.Case, async: true

  alias AshEnterprise.Telemetry.Correlation
  alias AshEnterprise.Telemetry.Logging
  alias OpenTelemetry.Tracer

  require OpenTelemetry.Tracer

  defp event, do: %{level: :info, msg: {:string, "x"}, meta: %{}}

  test "the filter adds the current span's ids and correlation" do
    id = Correlation.start_new()

    Tracer.with_span "logged" do
      %{meta: meta} = Logging.filter(event(), [])
      assert meta.otel_trace_id =~ ~r/^[0-9a-f]{32}$/
      assert meta.otel_span_id =~ ~r/^[0-9a-f]{16}$/
      assert meta.correlation_id == id
    end
  end

  test "outside a span and correlation it adds nothing" do
    assert %{meta: meta} = Logging.filter(event(), [])
    refute Map.has_key?(meta, :otel_trace_id)
    refute Map.has_key?(meta, :correlation_id)
  end

  test "a crash logged after the span closed still carries the failing span's ids" do
    trace_id =
      Tracer.with_span "crashed" do
        ids = Tracer.current_span_ctx() |> OpenTelemetry.Span.hex_span_ctx()
        AshEnterprise.Telemetry.FailedSpan.remember()
        ids.otel_trace_id
      end

    assert %{meta: %{otel_trace_id: ^trace_id}} = Logging.filter(event(), [])
  end

  test "a malformed event is left for the next filter" do
    assert Logging.filter(:garbage, []) == :ignore
  end

  test "the filter is attached by setup, and does not break logging" do
    assert {:ok, %{filters: filters}} = {:ok, :logger.get_primary_config()}
    assert Enum.any?(filters, fn {id, _} -> id == :ash_enterprise_telemetry_trace_context end)
  end

  describe "the export filter" do
    alias AshEnterprise.Telemetry.LogScrub

    defp log_event(msg, meta), do: %{level: :error, msg: msg, meta: Map.put(meta, :time, 0)}

    test "a host's own structured report and scalar metadata are exported as they are" do
      event = log_event({:report, %{order: "o-1", count: 2}}, %{request_id: "r-1", attempt: 3})

      assert %{msg: {:report, %{order: "o-1", count: 2}}, meta: meta} = LogScrub.filter(event, [])
      assert meta.request_id == "r-1"
      assert meta.attempt == 3
    end

    test "structured metadata is not exported" do
      event = log_event({:string, "x"}, %{form: %{"secret" => "meta-secret"}, conn: %{a: 1}})

      %{meta: meta} = LogScrub.filter(event, [])
      refute Map.has_key?(meta, :form)
      refute Map.has_key?(meta, :conn)
    end

    test "a URL's query values are not exported" do
      event = log_event({:string, "navigate event to http://h/p?token=url-secret failed"}, %{})

      assert %{msg: {:string, body}} = LogScrub.filter(event, [])
      refute body =~ "url-secret"
      assert body =~ "http://h/p?"
    end

    test "an event the filter cannot read is dropped, not exported unscrubbed" do
      assert LogScrub.filter(:garbage, []) == :stop
      assert LogScrub.filter(%{msg: {:string, "x"}, meta: :not_a_map}, []) == :stop
    end
  end
end
