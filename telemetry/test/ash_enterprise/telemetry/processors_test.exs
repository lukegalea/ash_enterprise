defmodule AshEnterprise.Telemetry.ProcessorsTest do
  # Registers a named process that the global batch exporter delivers to.
  use ExUnit.Case, async: false

  alias AshEnterprise.Telemetry
  alias AshEnterprise.Telemetry.SpanProcessor
  alias AshEnterprise.Telemetry.TestOtlpExporter
  alias AshEnterprise.Telemetry.TraceSink
  alias OpenTelemetry.Tracer

  require Record
  require OpenTelemetry.Tracer

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  defp exporter_of(list) do
    {:otel_batch_processor, %{exporter: exporter}} = List.last(list)
    exporter
  end

  describe "the generated list" do
    test "puts the batch processor last, where its `dropped` starves nothing" do
      assert [{SpanProcessor, %{}}, {TraceSink.Processor, %{}}, {:otel_batch_processor, _}] =
               Telemetry.processors(trace_sink: true)
    end

    test "omits what is switched off" do
      assert [{SpanProcessor, %{}}, {:otel_batch_processor, _}] = Telemetry.processors()

      assert [{SpanProcessor, %{}}, {TraceSink.Processor, %{}}] =
               Telemetry.processors(trace_sink: true, otlp: false)
    end

    test "the test environment runs exactly the generated list" do
      generated =
        Telemetry.processors(
          trace_sink: true,
          exporter: {TestOtlpExporter, []},
          scheduled_delay_ms: 20
        )

      assert Application.get_env(:opentelemetry, :processors) == generated
    end

    test "with no endpoint, the exporter is left to the environment" do
      assert exporter_of(Telemetry.processors()) == {:opentelemetry_exporter, %{}}
    end

    defp resolved_path(endpoint) do
      {:opentelemetry_exporter, config} =
        exporter_of(Telemetry.processors(otlp_endpoint: endpoint))

      %{endpoints: [resolved]} = :otel_exporter_traces_otlp.merge_with_environment(config)

      %{path: path} = if is_map(resolved), do: resolved, else: URI.parse(to_string(resolved))
      to_string(path)
    end

    test "the exporter resolves a base URL to one /v1/traces" do
      assert resolved_path("http://collector:4318") == "/v1/traces"
      assert resolved_path("http://collector:4318/") == "/v1/traces"
    end

    test "a URL that already has the path does not get it twice" do
      assert resolved_path("http://collector:4318/v1/traces") == "/v1/traces"
    end

    test "a base path is kept in front of the signal path" do
      assert resolved_path("http://collector/otlp") == "/otlp/v1/traces"
    end

    test "headers are passed on" do
      assert {:opentelemetry_exporter, %{headers: [{"x-key", "v"}]}} =
               exporter_of(Telemetry.processors(otlp_headers: [{"x-key", "v"}]))
    end
  end

  describe "the live chain" do
    test "the sink and the OTLP exporter both receive the same span" do
      Process.register(self(), :ash_telemetry_test_otlp)

      span_ctx =
        Tracer.with_span "dual.export" do
          Tracer.current_span_ctx()
        end

      span_id = OpenTelemetry.Span.span_id(span_ctx)
      trace_id = OpenTelemetry.Span.trace_id(span_ctx)

      assert %{root: %{name: "dual.export", span_id: ^span_id}} = TraceSink.trace(trace_id)
      assert_receive {:otlp_span, exported} when span(exported, :span_id) == span_id, 2_000
      assert span(exported, :name) == "dual.export"
    end

    test "a sink that is failing does not stop the span reaching OTLP" do
      assert TraceSink.Processor.on_end(:not_a_span_record, %{}) == true
    end
  end

  describe "TraceSink.Processor" do
    test "on_end is true for a sampled span, an unsampled span and garbage" do
      sampled =
        span(
          trace_id: 1,
          span_id: 2,
          trace_flags: 1,
          attributes: :otel_attributes.new(%{}, 128, :infinity)
        )

      unsampled = span(sampled, trace_flags: 0)

      assert TraceSink.Processor.on_end(sampled, %{}) == true
      assert TraceSink.Processor.on_end(unsampled, %{}) == true
      assert TraceSink.Processor.on_end(:garbage, %{}) == true
    end
  end

  describe "the ingest path" do
    defp request(path) do
      Plug.Test.conn(:post, path)
    end

    defp run_request(conn) do
      :telemetry.span([:bandit, :request], %{conn: conn}, fn -> {:ok, %{conn: conn}} end)
    end

    test "gets no server span, and leaves the next request's span alone" do
      AshEnterprise.Telemetry.TestKey.put(key = "ingest-#{System.unique_integer([:positive])}")

      run_request(request("/otel/v1/traces"))
      run_request(request("/real/path"))

      names = key |> TraceSink.by_test_key() |> Enum.flat_map(& &1.spans) |> Enum.map(& &1.name)
      assert names != []
      refute Enum.any?(names, &(&1 =~ "otel"))
      assert Enum.all?(names, &(to_string(&1) =~ "POST"))
    end
  end
end
