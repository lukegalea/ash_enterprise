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

    test "request bodies keep their shape and lose every value" do
      request = %Sentry.Interfaces.Request{
        data: %{"email" => "a@b.c", "plan" => "pro", "nested" => %{"name" => "Acme"}}
      }

      result = SentryWiring.before_send(event(request: request))

      assert result.request.data == %{
               "email" => "[Filtered]",
               "plan" => "[Filtered]",
               "nested" => %{"name" => "[Filtered]"}
             }
    end

    test "a body scrubber copes with an unparsed body and filters every value" do
      assert SentryWiring.scrub_body(%{params: %Plug.Conn.Unfetched{aspect: :params}}) == %{}

      assert SentryWiring.scrub_body(%{params: %{"secret" => "x", "name" => "Acme"}}) == %{
               "secret" => "[Filtered]",
               "name" => "[Filtered]"
             }
    end

    test "the query string goes, and a url keeps only its path" do
      request = %Sentry.Interfaces.Request{
        url: "https://app.test/reset?token=abc123",
        query_string: "token=abc123&q=acme",
        data: %{}
      }

      result = SentryWiring.before_send(event(request: request))

      assert result.request.query_string == nil
      assert result.request.url == "https://app.test/reset"
    end

    test "a token in the url's path is redacted" do
      request = %Sentry.Interfaces.Request{
        url: "https://app.test/password-reset/Xq3v9TzK1mNp7RwB2yLc?next=/app",
        data: %{}
      }

      result = SentryWiring.before_send(event(request: request))

      assert result.request.url == "https://app.test/password-reset/:token"
    end

    test "key and signature headers are filtered" do
      request = %Sentry.Interfaces.Request{
        headers: %{
          "x-webhook-key" => "whk-secret",
          "x-hub-signature-256" => "sha256=sig-secret",
          "accept" => "application/json"
        }
      }

      result = SentryWiring.before_send(event(request: request))

      assert result.request.headers["x-webhook-key"] == "[Filtered]"
      assert result.request.headers["x-hub-signature-256"] == "[Filtered]"
      assert result.request.headers["accept"] == "application/json"
    end

    test "a request with no body is still scrubbed" do
      request = %Sentry.Interfaces.Request{query_string: "token=abc123", cookies: %{"s" => "1"}}

      result = SentryWiring.before_send(event(request: request))

      assert result.request.query_string == nil
      refute inspect(result.request) =~ "abc123"
      refute result.request.cookies == %{"s" => "1"}
    end

    test "the client address does not leave in env or forwarding headers" do
      request = %Sentry.Interfaces.Request{
        env: %{"REMOTE_ADDR" => "203.0.113.9", "REMOTE_PORT" => 4000, "SERVER_NAME" => "app"},
        headers: %{
          "x-forwarded-for" => "203.0.113.9",
          "forwarded" => "for=203.0.113.9",
          "x-real-ip" => "203.0.113.9"
        }
      }

      result = SentryWiring.before_send(event(request: request))

      refute inspect(result.request) =~ "203.0.113.9"
      assert result.request.env["SERVER_NAME"] == "app"
    end

    test "a failure in scrubbing drops the event instead of sending it unscrubbed" do
      broken = %{event() | breadcrumbs: :not_a_list}
      assert SentryWiring.before_send(broken) == nil
    end

    test "stack frame variables are blanked on exceptions and threads" do
      frame = %Sentry.Interfaces.Stacktrace.Frame{
        function: "f",
        vars: %{"arg0" => ~s(%{"password" => "hunter2"})}
      }

      stacktrace = %Sentry.Interfaces.Stacktrace{frames: [frame]}

      result =
        SentryWiring.before_send(
          event(
            exception: [
              %Sentry.Interfaces.Exception{type: "E", value: "v", stacktrace: stacktrace}
            ],
            threads: [%Sentry.Interfaces.Thread{id: 1, stacktrace: stacktrace}]
          )
        )

      refute inspect(result) =~ "hunter2"
      assert hd(hd(result.exception).stacktrace.frames).function == "f"
      assert hd(hd(result.exception).stacktrace.frames).vars == %{}
      assert hd(hd(result.threads).stacktrace.frames).vars == %{}
    end

    test "an exception value that prints a runtime term loses the term" do
      original = %MatchError{term: %{"password" => "hunter2"}}

      result =
        SentryWiring.before_send(
          event(
            original_exception: original,
            exception: [
              %Sentry.Interfaces.Exception{type: "MatchError", value: Exception.message(original)}
            ]
          )
        )

      refute inspect(result.exception) =~ "hunter2"
    end

    test "Last message, State and task arguments are dropped from a crash message" do
      for tail <- [
            "\nLast message: %{password: \"hunter2\"}\nState: %{token: \"hunter2\"}",
            "\nState: %{token: \"hunter2\"}",
            "\nFunction: &Mod.fun/1\n    Args: [\"hunter2\"]"
          ] do
        text = "GenServer #PID<0.1.0> terminating\n** (stop) :bad" <> tail
        message = %Sentry.Interfaces.Message{formatted: text, message: text, params: ["hunter2"]}

        result = SentryWiring.before_send(event(message: message))

        refute inspect(result.message) =~ "hunter2", "leaked with tail: #{tail}"
        assert result.message.formatted =~ "terminating"
      end
    end

    test "a crash's process state does not stay in extra" do
      result =
        SentryWiring.before_send(
          event(extra: %{genserver_state: "hunter2", last_message: "hunter2", kept: "yes"})
        )

      refute inspect(result.extra) =~ "hunter2"
      assert result.extra.kept == "yes"
    end

    test "an exit reason in extra, a call in the fingerprint and a call's message are not sent" do
      text =
        "exited in: GenServer.call(#PID<0.1.0>, {:get, \"call-secret\"}, 5000)\n    ** (EXIT) time out"

      result =
        SentryWiring.before_send(
          event(
            extra: %{crash_reason: inspect({:bad_state, "reason-secret"})},
            fingerprint: ["timeout", "genserver_call", inspect({:get, "fingerprint-secret"})],
            message: %Sentry.Interfaces.Message{formatted: text, message: text, params: nil}
          )
        )

      sent = inspect(result, limit: :infinity, printable_limit: :infinity)
      refute sent =~ "reason-secret"
      refute sent =~ "fingerprint-secret"
      refute sent =~ "call-secret"
      assert result.fingerprint == ["timeout", "genserver_call"]
      assert result.message.formatted =~ "GenServer.call/?"
    end

    test "a crash's frame arguments are not sent in its message" do
      text = """
      GenServer #PID<0.1.0> terminating
      ** (FunctionClauseError) no function clause matching in MyApp.Live.handle_event/3
          (my_app 0.1.0) lib/my_app/live.ex:12: MyApp.Live.handle_event("crash-form", %{"secret" => "frame-secret"}, socket)
      """

      result =
        SentryWiring.before_send(
          event(message: %Sentry.Interfaces.Message{formatted: text, message: text, params: nil})
        )

      refute inspect(result.message) =~ "frame-secret"
      assert result.message.formatted =~ "MyApp.Live.handle_event/?"
    end
  end

  describe "Sentry structured logs" do
    defp log_event(attrs) do
      struct!(%Sentry.LogEvent{level: :error, body: "", timestamp: 0.0}, attrs)
    end

    test "before_send_log scrubs a crash body and keeps scalar attributes only" do
      body = """
      GenServer #PID<0.1.0> terminating
      ** (MatchError) no match of right hand side value:

          {:error, "value-secret"}

          (my_app 0.1.0) lib/my_app/server.ex:9: MyApp.Server.handle_cast/2
      Last message: {:"$gen_cast", {:crash, "message-secret"}}
      State: %{token: "state-secret"}
      """

      result =
        SentryWiring.before_send_log(
          log_event(
            body: body,
            template: body,
            parameters: [%{token: "parameter-secret"}, "kept-parameter"],
            attributes: %{
              crash_reason: {%MatchError{term: "attribute-secret"}, []},
              request_id: "r-1",
              form: %{"secret" => "map-secret"}
            }
          )
        )

      sent = inspect(result, limit: :infinity, printable_limit: :infinity)

      for secret <-
            ~w(value-secret message-secret state-secret parameter-secret attribute-secret map-secret) do
        refute sent =~ secret
      end

      assert result.body =~ "GenServer #PID<0.1.0> terminating"
      assert result.body =~ "MyApp.Server.handle_cast/2"
      assert result.attributes == %{request_id: "r-1"}
    end

    test "before_send_log drops what it cannot read" do
      assert SentryWiring.before_send_log(:garbage) == nil
    end
  end

  describe "LiveView scrubbing" do
    test "only a top-level event name is kept" do
      assert SentryWiring.scrub_live_view_params(%{
               "event" => "save",
               "form" => %{"event" => "customer text", "name" => "Acme"}
             }) == %{
               "event" => "save",
               "form" => %{"event" => "[Filtered]", "name" => "[Filtered]"}
             }
    end

    test "a non-string event is filtered" do
      assert SentryWiring.scrub_live_view_params(%{"event" => %{"a" => "x"}}) == %{
               "event" => %{"a" => "[Filtered]"}
             }
    end

    test "a live_view.info breadcrumb loses its message" do
      crumb = %Sentry.Interfaces.Breadcrumb{
        category: "web.live_view.info",
        message: ~s({:updated, %{password: "hunter2"}})
      }

      [result] = SentryWiring.before_send(event(breadcrumbs: [crumb])).breadcrumbs
      refute inspect(result) =~ "hunter2"
    end

    test "a live_view.params breadcrumb loses the query in its message" do
      crumb = %Sentry.Interfaces.Breadcrumb{
        category: "web.live_view.params",
        message: "https://app.test/page?token=hunter2",
        data: %{params: %{"token" => "hunter2"}, uri: "https://app.test/page?token=hunter2"}
      }

      [result] = SentryWiring.before_send(event(breadcrumbs: [crumb])).breadcrumbs
      refute inspect(result) =~ "hunter2"
      assert result.message == "https://app.test/page"
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
