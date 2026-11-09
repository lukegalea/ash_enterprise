defmodule AshEnterprise.Telemetry.SentryWiringTest do
  use ExUnit.Case, async: true

  alias AshEnterprise.Telemetry.Correlation
  alias AshEnterprise.Telemetry.SentryWiring
  alias OpenTelemetry.Tracer

  require OpenTelemetry.Tracer

  defp event(attrs \\ []) do
    Sentry.Event.create_event(message: "boom") |> struct!(attrs)
  end

  describe "before_send tags" do
    test "adds trace, span and correlation from the live context" do
      id = Correlation.start_new()

      Tracer.with_span "reporting" do
        result = SentryWiring.before_send(event())
        assert result.tags["trace_id"] =~ ~r/^[0-9a-f]{32}$/
        assert result.tags["span_id"] =~ ~r/^[0-9a-f]{16}$/
        assert result.tags["correlation_id"] == id
      end
    end

    test "falls back to the event's trace context when no span is live" do
      trace_id = String.duplicate("a", 32)

      result =
        SentryWiring.before_send(event(contexts: %{trace: %{trace_id: trace_id, span_id: "b"}}))

      assert result.tags["trace_id"] == trace_id
    end

    test "uses the remembered failing span when the context has already been detached" do
      {trace_id, span_id} =
        Tracer.with_span "crashed" do
          ids = OpenTelemetry.Tracer.current_span_ctx() |> OpenTelemetry.Span.hex_span_ctx()
          AshEnterprise.Telemetry.FailedSpan.remember()
          {ids.otel_trace_id, ids.otel_span_id}
        end

      assert Tracer.current_span_ctx() == :undefined

      result = SentryWiring.before_send(event())
      assert result.tags["trace_id"] == trace_id
      assert result.tags["span_id"] == span_id
    end

    test "omits tags with nothing to say, and keeps the host's own" do
      result = SentryWiring.before_send(event(tags: %{"region" => "ca"}))
      assert result.tags == %{"region" => "ca"}
    end
  end

  describe "scrubbing" do
    test "LiveView event breadcrumbs keep their shape and lose their values" do
      crumb = %{
        category: "web.live_view.event",
        data: %{event: "save", params: %{"email" => "a@b.c", "nested" => %{"x" => "y"}}}
      }

      [scrubbed] = SentryWiring.before_send(event(breadcrumbs: [crumb])).breadcrumbs

      assert scrubbed.data.event == "save"

      assert scrubbed.data.params == %{
               "email" => "[Filtered]",
               "nested" => %{"x" => "[Filtered]"}
             }
    end

    test "other breadcrumbs are untouched" do
      crumb = %{category: "http", data: %{url: "/x"}}
      assert [^crumb] = SentryWiring.before_send(event(breadcrumbs: [crumb])).breadcrumbs
    end

    test "user PII is removed" do
      result =
        SentryWiring.before_send(
          event(user: %{id: "1", email: "a@b.c", ip_address: "1.2.3.4", username: "x"})
        )

      assert result.user == %{id: "1"}
    end

    test "sensitive keys in extra and request data are filtered, recursively" do
      extra = %{token: "s", note: "ok", nested: %{"password" => "p", list: [%{"api_key" => "k"}]}}
      result = SentryWiring.before_send(event(extra: extra))

      assert result.extra.token == "[Filtered]"
      assert result.extra.note == "ok"
      assert result.extra.nested["password"] == "[Filtered]"
      assert [%{"api_key" => "[Filtered]"}] = result.extra.nested.list
    end

    test "request bodies are scrubbed" do
      request = %Sentry.Interfaces.Request{data: %{"email" => "a@b.c", "plan" => "pro"}}
      result = SentryWiring.before_send(event(request: request))
      assert result.request.data == %{"email" => "[Filtered]", "plan" => "pro"}
    end

    test "a body scrubber copes with an unparsed body" do
      assert SentryWiring.scrub_body(%{params: %Plug.Conn.Unfetched{aspect: :params}}) == %{}
      assert SentryWiring.scrub_body(%{params: %{"secret" => "x"}}) == %{"secret" => "[Filtered]"}
    end

    test "a callback failure returns the event rather than losing it" do
      broken = %{event() | breadcrumbs: :not_a_list}
      assert %Sentry.Event{} = SentryWiring.before_send(broken)
    end
  end

  describe "the Oban final-attempt policy" do
    test "reports only when retries are exhausted" do
      refute SentryWiring.final_attempt?(nil, %{attempt: 1, max_attempts: 20})
      refute SentryWiring.final_attempt?(nil, %{attempt: 19, max_attempts: 20})
      assert SentryWiring.final_attempt?(nil, %{attempt: 20, max_attempts: 20})
      assert SentryWiring.final_attempt?(nil, %{attempt: 1, max_attempts: 1})
    end
  end

  test "Sentry's own span processor and sampler are not configured" do
    refute Application.get_env(:sentry, :traces_sample_rate)
    refute Application.get_env(:opentelemetry, :span_processor)
    refute Application.get_env(:opentelemetry, :sampler)
  end
end
