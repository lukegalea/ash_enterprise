defmodule AshEnterprise.Telemetry.SpanExceptionTest do
  # `trace_url` and `enduser_name?` are application env.
  use ExUnit.Case, async: false

  alias AshEnterprise.Telemetry.FailedSpan
  alias AshEnterprise.Telemetry.SentryWiring
  alias OpenTelemetry.Tracer

  import AshEnterprise.Telemetry.TraceHelpers

  require OpenTelemetry.Tracer

  setup do
    previous =
      Application.get_all_env(:ash_enterprise_telemetry)
      |> Keyword.take([:trace_url, :enduser_name?])

    on_exit(fn ->
      Application.delete_env(:ash_enterprise_telemetry, :trace_url)
      Application.delete_env(:ash_enterprise_telemetry, :enduser_name?)
      for {key, value} <- previous, do: Application.put_env(:ash_enterprise_telemetry, key, value)
    end)

    :ok
  end

  defp exception_event(attrs \\ []) do
    {exception, stacktrace} =
      try do
        raise ArgumentError, "bad input"
      rescue
        error -> {error, __STACKTRACE__}
      end

    Sentry.Event.create_event(exception: exception, stacktrace: stacktrace) |> struct!(attrs)
  end

  defp exception_events(span), do: Enum.filter(span.events, &(&1.name == "exception"))

  defp hex(id, size),
    do: id |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(size, "0")

  test "a report made inside a span is recorded on that span" do
    key = test_key!()

    result =
      Tracer.with_span "work" do
        SentryWiring.before_send(exception_event())
      end

    span = span_named(key, "work")
    assert [event] = exception_events(span)
    assert event.attributes[:"exception.type"] == "ArgumentError"
    assert event.attributes[:"exception.message"] == "bad input"
    assert event.attributes[:"exception.stacktrace"] =~ "SpanExceptionTest"
    assert result.tags["span_id"] == hex(span.span_id, 16)
    assert result.tags["trace_id"] == hex(span.trace_id, 32)
  end

  test "a report outside any span gets a short error span of its own" do
    key = test_key!()
    result = SentryWiring.before_send(exception_event())

    span = span_named(key, "error.report")
    assert span.status_code == :error
    assert [_event] = exception_events(span)
    assert result.tags["trace_id"] == hex(span.trace_id, 32)
    assert result.contexts.trace.span_id == hex(span.span_id, 16)
  end

  test "a crash the logger reported is a process.crash span" do
    key = test_key!()
    SentryWiring.before_send(exception_event(source: :logger))
    assert span_named(key, "process.crash")
  end

  test "an event that names a trace gets its span in that trace" do
    key = test_key!()
    trace_id = String.duplicate("c", 32)

    result =
      SentryWiring.before_send(
        exception_event(
          contexts: %{trace: %{trace_id: trace_id, span_id: String.duplicate("d", 16)}}
        )
      )

    assert result.tags["trace_id"] == trace_id
    assert hex(span_named(key, "error.report").trace_id, 32) == trace_id
  end

  test "a failure a library already recorded on its span is not recorded twice" do
    key = test_key!()

    Tracer.with_span "already" do
      FailedSpan.remember()
    end

    SentryWiring.before_send(exception_event())
    refute span_named(key, "error.report")
    assert exception_events(span_named(key, "already")) == []
  end

  test "warnings are left alone" do
    key = test_key!()
    SentryWiring.before_send(exception_event(level: :warning))
    refute span_named(key, "error.report")
  end

  test "the trace link is added when a template is configured" do
    Application.put_env(
      :ash_enterprise_telemetry,
      :trace_url,
      "https://traces.example/trace/{trace_id}"
    )

    result = SentryWiring.before_send(exception_event())

    assert result.tags["trace_url"] == "https://traces.example/trace/" <> result.tags["trace_id"]
  end

  test "the username stays only when names are recorded" do
    user = %{id: "1", username: "pat", email: "pat@example.test"}

    assert SentryWiring.before_send(exception_event(level: :warning, user: user)).user == %{
             id: "1"
           }

    Application.put_env(:ash_enterprise_telemetry, :enduser_name?, true)

    assert SentryWiring.before_send(exception_event(level: :warning, user: user)).user == %{
             id: "1",
             username: "pat"
           }
  end
end
