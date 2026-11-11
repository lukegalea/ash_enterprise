defmodule AshEnterprise.Telemetry.SpanProcessorTest do
  use ExUnit.Case, async: false

  alias AshEnterprise.Telemetry.Correlation
  alias AshEnterprise.Telemetry.RaisingCorrelation
  alias AshEnterprise.Telemetry.Settings
  alias AshEnterprise.Telemetry.SpanProcessor

  import AshEnterprise.Telemetry.TraceHelpers

  require OpenTelemetry.Tracer

  test "stamps the correlation id and test key at start" do
    key = test_key!()
    id = Correlation.start_new()

    OpenTelemetry.Tracer.with_span "stamped.span" do
      :ok
    end

    span = span_named(key, "stamped.span")
    assert attr(span, "ash.correlation_id") == id
    assert attr(span, "ash.test_key") == key
  end

  test "a correlation id the caller set on the span wins, under a string or atom key" do
    key = test_key!()
    Correlation.start_new()

    OpenTelemetry.Tracer.with_span "caller.string", %{
      attributes: %{"ash.correlation_id" => "from-the-row"}
    } do
      :ok
    end

    OpenTelemetry.Tracer.with_span "caller.atom", %{
      attributes: %{"ash.correlation_id": "from-the-atom"}
    } do
      :ok
    end

    assert attr(span_named(key, "caller.string"), "ash.correlation_id") == "from-the-row"
    atom_span = span_named(key, "caller.atom")
    assert atom_span.attributes[:"ash.correlation_id"] == "from-the-atom"
    assert attr(atom_span, "ash.correlation_id") == nil
  end

  test "stamps at start, so a correlation set later does not apply" do
    key = test_key!()

    OpenTelemetry.Tracer.with_span "started.before" do
      Correlation.start_new()
    end

    assert attr(span_named(key, "started.before"), "ash.correlation_id") == nil
  end

  test "never generates a correlation id" do
    key = test_key!()
    assert Correlation.current() == nil

    OpenTelemetry.Tracer.with_span "no.correlation" do
      :ok
    end

    assert attr(span_named(key, "no.correlation"), "ash.correlation_id") == nil
    assert Correlation.current() == nil
  end

  test "marks a remote parent, and only a remote parent" do
    key = test_key!()
    %{header: header} = traceparent()
    ctx = :otel_propagator_text_map.extract_to(OpenTelemetry.Ctx.new(), [{"traceparent", header}])

    token = OpenTelemetry.Ctx.attach(ctx)

    OpenTelemetry.Tracer.with_span "remote.child" do
      OpenTelemetry.Tracer.with_span "local.child" do
        :ok
      end
    end

    OpenTelemetry.Ctx.detach(token)

    assert attr(span_named(key, "remote.child"), "ash.parent_remote") == true
    assert attr(span_named(key, "local.child"), "ash.parent_remote") == nil
  end

  test "a raising correlation module does not break span creation" do
    original = Settings.correlation()
    Settings.put(%{correlation: RaisingCorrelation})

    try do
      key = test_key!()

      result =
        OpenTelemetry.Tracer.with_span "survives.correlation" do
          :still_runs
        end

      assert result == :still_runs
      assert span_named(key, "survives.correlation")
    after
      Settings.put(%{
        correlation: original,
        browser_context?: true,
        event_attributes: {AshEnterprise.Telemetry.TestEventAttributes, :resolve, []}
      })
    end
  end

  test "on_start returns the span untouched on bad input" do
    assert SpanProcessor.on_start(:not_a_ctx, {:not, :a, :span}, %{}) == {:not, :a, :span}
  end

  test "on_end returns true, on every input" do
    assert SpanProcessor.on_end(:not_a_span, %{}) == true
    assert SpanProcessor.on_end({:span, :garbage}, :garbage) == true
  end
end
