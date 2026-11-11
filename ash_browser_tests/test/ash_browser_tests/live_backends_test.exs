defmodule AshBrowserTests.LiveBackendsTest do
  @moduledoc false
  # Reads a real SigNoz and GlitchTip. Excluded by default; see README.md.
  use ExUnit.Case, async: false

  @moduletag :live_backends
  @moduletag timeout: 90_000

  alias AshBrowserTests.Backend
  alias AshBrowserTests.Backend.GlitchTip
  alias AshBrowserTests.Backend.SigNoz
  alias AshBrowserTests.Trace

  defp hex(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp env!(name), do: System.fetch_env!(name)

  defp send_otlp(trace, key) do
    now = System.system_time(:nanosecond)

    span = fn name, span_id, parent, extra ->
      Map.merge(
        %{
          "traceId" => trace,
          "spanId" => span_id,
          "parentSpanId" => parent,
          "name" => name,
          "kind" => 2,
          "startTimeUnixNano" => to_string(now),
          "endTimeUnixNano" => to_string(now + 1_000_000),
          "attributes" => [%{"key" => "ash.test_key", "value" => %{"stringValue" => key}}],
          "status" => %{}
        },
        extra
      )
    end

    root = hex(8)
    child = hex(8)

    payload = %{
      "resourceSpans" => [
        %{
          "resource" => %{
            "attributes" => [
              %{"key" => "service.name", "value" => %{"stringValue" => "abt-live"}}
            ]
          },
          "scopeSpans" => [
            %{
              "scope" => %{"name" => "live"},
              "spans" => [
                span.("root", root, "", %{}),
                span.("child", child, root, %{
                  "status" => %{"code" => 2, "message" => "boom"},
                  "events" => [
                    %{
                      "name" => "exception",
                      "timeUnixNano" => to_string(now),
                      "attributes" => [
                        %{
                          "key" => "exception.type",
                          "value" => %{"stringValue" => "RuntimeError"}
                        },
                        %{
                          "key" => "exception.message",
                          "value" => %{"stringValue" => "live boom"}
                        }
                      ]
                    }
                  ]
                })
              ]
            }
          ]
        }
      ]
    }

    Req.post!(env!("SIGNOZ_OTLP_URL") <> "/v1/traces", json: payload, retry: false)
    {root, child}
  end

  test "SigNoz: a span sent over OTLP comes back by trace id, by key, and with its exception" do
    trace = hex(16)
    key = "live-#{hex(4)}"
    {root, child} = send_otlp(trace, key)

    opts = [
      backend: SigNoz,
      url: env!("SIGNOZ_URL"),
      api_key: env!("SIGNOZ_API_KEY"),
      poll_ms: 500
    ]

    {:ok, by_trace} = Backend.spans_for({:trace_id, trace}, 60_000, opts)
    assert Enum.sort(Enum.map(by_trace, & &1.span_id)) == Enum.sort([root, child])
    assert [_root, _child] = Trace.assert_chain(by_trace, ["root", "child"])

    {:ok, by_key} = Backend.spans_for(key, 60_000, opts)
    assert length(by_key) == 2

    {:ok, errored} =
      Backend.spans_for({:trace_id, trace}, 60_000, Keyword.put(opts, :only_errors, true))

    assert Trace.assert_exception(errored, type: "RuntimeError", message: ~r/live boom/).name ==
             "child"
  end

  test "GlitchTip: an envelope carrying a trace id tag is found by that tag" do
    trace = hex(16)
    event_id = hex(16)
    dsn = URI.parse(env!("GLITCHTIP_DSN"))
    host = "#{dsn.scheme}://#{dsn.host}:#{dsn.port}"
    project = String.trim_leading(dsn.path, "/")

    event = %{
      "event_id" => event_id,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "platform" => "elixir",
      "level" => "error",
      "tags" => %{"trace_id" => trace},
      "exception" => %{"values" => [%{"type" => "RuntimeError", "value" => "live glitch"}]}
    }

    envelope =
      [
        Jason.encode!(%{"event_id" => event_id}),
        Jason.encode!(%{"type" => "event"}),
        Jason.encode!(event)
      ]
      |> Enum.join("\n")

    Req.post!("#{host}/api/#{project}/envelope/",
      body: envelope,
      headers: [{"x-sentry-auth", "Sentry sentry_key=#{dsn.userinfo}, sentry_version=7"}],
      retry: false
    )

    opts = [
      backend: GlitchTip,
      url: env!("GLITCHTIP_URL"),
      token: env!("GLITCHTIP_TOKEN"),
      organization: env!("GLITCHTIP_ORG"),
      poll_ms: 500
    ]

    {:ok, [issue | _]} = Backend.spans_for({:trace_id, trace}, 60_000, opts)
    assert Trace.assert_exception([issue], type: "RuntimeError", message: ~r/live glitch/)
    assert issue.trace_id == trace
  end
end
