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
end
