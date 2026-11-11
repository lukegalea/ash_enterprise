defmodule AshEnterprise.Telemetry.OtlpIngestTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AshEnterprise.Telemetry.OtlpIngest
  alias AshEnterprise.Telemetry.OtlpIngest.Limiter
  alias AshEnterprise.Telemetry.TraceSink

  @path "/otel/v1/traces"
  @host "app.example.test"

  defp id(bytes), do: :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)

  defp attribute(key, value), do: %{"key" => key, "value" => %{"stringValue" => value}}

  defp span(opts \\ []) do
    %{
      "traceId" => Keyword.get(opts, :trace_id, id(16)),
      "spanId" => Keyword.get(opts, :span_id, id(8)),
      "name" => Keyword.get(opts, :name, "browser"),
      "startTimeUnixNano" => "1700000000000000000",
      "endTimeUnixNano" => "1700000000001000000",
      "attributes" => Keyword.get(opts, :attributes, [attribute("ui.page.path", "/x")])
    }
  end

  defp payload(spans) do
    %{
      "resourceSpans" => [
        %{"resource" => %{"attributes" => []}, "scopeSpans" => [%{"spans" => spans}]}
      ]
    }
  end

  defp request(body, opts \\ []) do
    :post
    |> conn(@path, if(is_binary(body), do: body, else: Jason.encode!(body)))
    |> then(&%{&1 | req_headers: [{"host", Keyword.get(opts, :host, @host)} | &1.req_headers]})
    |> put_req_header("content-type", Keyword.get(opts, :content_type, "application/json"))
    |> then(fn conn ->
      case Keyword.get(opts, :origin, "https://#{@host}") do
        nil -> conn
        origin -> put_req_header(conn, "origin", origin)
      end
    end)
    |> then(fn conn ->
      %{
        conn
        | remote_ip:
            Keyword.get(
              opts,
              :remote_ip,
              {10, 0, 0, System.unique_integer([:positive]) |> rem(250)}
            )
      }
    end)
  end

  defp call(conn, opts \\ []), do: OtlpIngest.call(conn, OtlpIngest.init(opts))

  describe "rejections" do
    test "only POST is accepted" do
      for method <- [:get, :put, :delete] do
        conn = method |> conn(@path) |> call()
        assert conn.status == 405
        assert conn.halted
      end
    end

    test "a wrong content type is rejected" do
      for type <- ["text/plain", "application/x-protobuf", "application/x-www-form-urlencoded"] do
        assert (payload([span()]) |> request(content_type: type) |> call()).status == 415
      end
    end

    test "a compressed body is rejected" do
      conn =
        payload([span()]) |> request() |> put_req_header("content-encoding", "gzip") |> call()

      assert conn.status == 415
    end

    test "a cross-origin request is rejected" do
      for origin <- ["https://evil.example", "https://#{@host}.evil.example", "null"] do
        assert (payload([span()]) |> request(origin: origin) |> call()).status == 403,
               "accepted #{origin}"
      end
    end

    test "a missing Origin is rejected" do
      assert (payload([span()]) |> request(origin: nil) |> call()).status == 403
    end

    test "a different port on the same host is a different origin" do
      conn =
        payload([span()])
        |> request(origin: "http://#{@host}:9999", host: "#{@host}:4000")
        |> call()

      assert conn.status == 403
    end

    test "an oversize body is rejected" do
      body = String.duplicate("a", 262_145)
      assert (body |> request() |> call()).status == 413
    end

    test "too many spans are rejected" do
      conn = [span(), span(), span()] |> payload() |> request() |> call(max_spans: 2)
      assert conn.status == 413
    end

    test "a non-JSON or wrongly-shaped body is rejected" do
      assert ("{not json" |> request() |> call()).status == 400
      assert (%{"other" => 1} |> request() |> call()).status == 400
      assert (%{"resourceSpans" => "nope"} |> request() |> call()).status == 400
    end

    test "a client over its rate limit gets 429, and another client does not" do
      ip = {192, 168, 1, System.unique_integer([:positive]) |> rem(250)}

      limited = fn remote_ip ->
        payload([span()]) |> request(remote_ip: remote_ip) |> call(rate_limit: 2)
      end

      assert limited.(ip).status == 200
      assert limited.(ip).status == 200
      assert limited.(ip).status == 429
      assert limited.({192, 168, 2, 1}).status == 200
    end

    test "the limiter fails closed when its table is gone" do
      assert Limiter.allow?(:some_key, 10, :no_such_table) == false
    end
  end

  describe "acceptance" do
    test "a same-origin batch reaches the sink" do
      trace_id = id(16)
      conn = payload([span(trace_id: trace_id, name: "/page Save")]) |> request() |> call()

      assert conn.status == 200
      assert conn.halted
      assert TraceSink.trace(trace_id).root.name == "/page Save"
    end

    test "a page-unload beacon is accepted: a cookie, no CSRF token, a bare JSON content type" do
      trace_id = id(16)

      conn =
        payload([span(trace_id: trace_id, name: "/page Crash")])
        |> request(content_type: "application/json")
        |> put_req_header("cookie", "_session=abc")
        |> call()

      assert get_req_header(conn, "x-csrf-token") == []
      assert conn.status == 200
      assert TraceSink.trace(trace_id).root.name == "/page Crash"
    end

    test "with no Host header, the conn's host and port are the authority" do
      conn =
        :post
        |> conn(@path, Jason.encode!(payload([span()])))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "http://www.example.com")
        |> call()

      assert conn.status == 200
    end

    test "a configured extra origin is allowed" do
      conn =
        payload([span()])
        |> request(origin: "https://proxy.example.test")
        |> call(allowed_origins: ["https://proxy.example.test"])

      assert conn.status == 200
    end

    test "the scheme is ignored, for a TLS-terminating proxy" do
      assert (payload([span()]) |> request(origin: "http://#{@host}") |> call()).status == 200
    end

    test "disabled, it passes the request through" do
      conn = payload([span()]) |> request() |> call(enabled: false)
      assert conn.status == nil
      refute conn.halted
    end

    test "another path passes through" do
      conn = :post |> conn("/other") |> call()
      assert conn.status == nil
      refute conn.halted
    end
  end

  describe "sanitizing" do
    defp keys(attributes), do: Enum.map(attributes, & &1["key"])

    defp sanitized_span(span, trusted \\ %{}) do
      %{"resourceSpans" => [%{"scopeSpans" => [%{"spans" => [result]}]}]} =
        OtlpIngest.sanitize(payload([span]), trusted)

      result
    end

    test "strips reserved attributes from span, events and links" do
      reserved = [
        attribute("ash.correlation_id", "forged"),
        attribute("ash.test_key", "forged"),
        attribute("audit.actor", "forged"),
        attribute("correlation_id", "forged"),
        attribute("my.correlation.id", "forged"),
        attribute("ui.page.path", "/kept")
      ]

      result =
        span(attributes: reserved)
        |> Map.put("events", [%{"name" => "e", "attributes" => reserved}])
        |> Map.put("links", [%{"traceId" => id(16), "spanId" => id(8), "attributes" => reserved}])
        |> sanitized_span()

      assert keys(result["attributes"]) == ["ui.page.path"]
      assert keys(hd(result["events"])["attributes"]) == ["ui.page.path"]
      assert keys(hd(result["links"])["attributes"]) == ["ui.page.path"]
    end

    test "strips reserved attributes from the resource" do
      body = %{
        "resourceSpans" => [
          %{
            "resource" => %{
              "attributes" => [
                attribute("ash.correlation_id", "x"),
                attribute("service.name", "browser")
              ]
            },
            "scopeSpans" => []
          }
        ]
      }

      assert %{"resourceSpans" => [%{"resource" => %{"attributes" => attributes}}]} =
               OtlpIngest.sanitize(body, %{})

      assert keys(attributes) == ["service.name"]
    end

    test "strips reserved attributes from the instrumentation scope and drops its other keys" do
      body = %{
        "resourceSpans" => [
          %{
            "resource" => %{"attributes" => []},
            "scopeSpans" => [
              %{
                "scope" => %{
                  "name" => "browser",
                  "version" => "1",
                  "smuggled" => "x",
                  "attributes" => [attribute("ash.test_key", "forged"), attribute("kept", "y")]
                },
                "spans" => []
              }
            ]
          }
        ]
      }

      assert %{"resourceSpans" => [%{"scopeSpans" => [%{"scope" => scope}]}]} =
               OtlpIngest.sanitize(body, %{})

      assert Map.keys(scope) |> Enum.sort() == ["attributes", "name", "version"]
      assert keys(scope["attributes"]) == ["kept"]
    end

    test "a long status message is truncated and unknown status keys are dropped" do
      result =
        span()
        |> Map.put("status", %{
          "code" => 2,
          "message" => String.duplicate("x", 5_000),
          "smuggled" => "y"
        })
        |> sanitized_span()

      assert result["status"]["code"] == 2
      assert byte_size(result["status"]["message"]) == 1_024
      refute Map.has_key?(result["status"], "smuggled")
    end

    test "a malformed status or scope is dropped rather than crashing the plug" do
      assert sanitized_span(Map.put(span(), "status", "nope")) |> Map.has_key?("status") == false

      body = %{
        "resourceSpans" => [%{"scopeSpans" => [%{"scope" => "nope", "spans" => []}]}]
      }

      assert %{"resourceSpans" => [%{"scopeSpans" => [%{"scope" => %{"attributes" => []}}]}]} =
               OtlpIngest.sanitize(body, %{})
    end

    test "drops spans with malformed ids" do
      bad = [
        span(trace_id: "short"),
        span(trace_id: String.duplicate("0", 32)),
        span(span_id: String.duplicate("0", 16)),
        span(span_id: "GGGGGGGGGGGGGGGG")
      ]

      assert %{"resourceSpans" => [%{"scopeSpans" => [%{"spans" => []}]}]} =
               OtlpIngest.sanitize(payload(bad), %{})
    end

    test "truncates long names and values, and caps counts" do
      many = for n <- 1..200, do: attribute("k#{n}", "v")

      result =
        span(
          name: String.duplicate("n", 5_000),
          attributes: [attribute("long", String.duplicate("v", 5_000)) | many]
        )
        |> Map.put("events", for(_ <- 1..100, do: %{"name" => "e"}))
        |> Map.put("links", for(_ <- 1..100, do: %{"traceId" => id(16), "spanId" => id(8)}))
        |> sanitized_span()

      assert byte_size(result["name"]) == 1_024
      assert byte_size(hd(result["attributes"])["value"]["stringValue"]) == 1_024
      assert length(result["attributes"]) == 64
      assert length(result["events"]) == 32
      assert length(result["links"]) == 8
    end

    test "truncation keeps multi-byte text valid, so the forward can encode it" do
      long = String.duplicate("日本語", 1_000)

      result =
        span(name: long, attributes: [attribute("long", long)])
        |> Map.put("status", %{"code" => 2, "message" => long})
        |> Map.put("events", [%{"name" => long}])
        |> sanitized_span()

      assert String.valid?(result["name"])
      assert byte_size(result["name"]) <= 1_024
      assert String.valid?(hd(result["attributes"])["value"]["stringValue"])
      assert String.valid?(result["status"]["message"])
      assert String.valid?(hd(result["events"])["name"])
      assert {:ok, _json} = Jason.encode(result)
    end

    test "only scalar attribute values survive" do
      nested = %{
        "kvlistValue" => %{"values" => [attribute("ash.correlation_id", "forged")]}
      }

      result =
        span(
          attributes: [
            %{"key" => "nested", "value" => nested},
            %{
              "key" => "array",
              "value" => %{"arrayValue" => %{"values" => [%{"stringValue" => "x"}]}}
            },
            %{"key" => "bytes", "value" => %{"bytesValue" => "AAAA"}},
            %{"key" => "bad_int", "value" => %{"intValue" => %{"a" => 1}}},
            %{"key" => "bad_bool", "value" => %{"boolValue" => "yes"}},
            %{"key" => "bad_double", "value" => %{"doubleValue" => "1.0"}},
            %{"key" => "bad_string", "value" => %{"stringValue" => %{"a" => 1}}},
            %{"key" => "mixed", "value" => %{"stringValue" => "x", "arrayValue" => %{}}},
            %{"key" => "s", "value" => %{"stringValue" => "kept"}},
            %{"key" => "b", "value" => %{"boolValue" => false}},
            %{"key" => "i", "value" => %{"intValue" => "42"}},
            %{"key" => "n", "value" => %{"intValue" => 42}},
            %{"key" => "d", "value" => %{"doubleValue" => 1.5}}
          ]
        )
        |> sanitized_span()

      assert keys(result["attributes"]) == ["s", "b", "i", "n", "d"]
      refute inspect(result) =~ "forged"
    end

    test "a scalar rule applies to events, links, scopes and resources too" do
      nested = %{"key" => "n", "value" => %{"kvlistValue" => %{"values" => []}}}
      kept = attribute("kept", "y")

      body = %{
        "resourceSpans" => [
          %{
            "resource" => %{"attributes" => [nested, kept], "smuggled" => "x"},
            "scopeSpans" => [
              %{
                "scope" => %{"name" => "s", "attributes" => [nested, kept]},
                "spans" => [
                  span()
                  |> Map.put("events", [%{"name" => "e", "attributes" => [nested, kept]}])
                  |> Map.put("links", [
                    %{"traceId" => id(16), "spanId" => id(8), "attributes" => [nested, kept]}
                  ])
                ]
              }
            ]
          }
        ]
      }

      assert %{"resourceSpans" => [%{"resource" => resource, "scopeSpans" => [scope_spans]}]} =
               OtlpIngest.sanitize(body, %{})

      assert Map.keys(resource) == ["attributes"]
      assert keys(resource["attributes"]) == ["kept"]
      assert keys(scope_spans["scope"]["attributes"]) == ["kept"]
      [out] = scope_spans["spans"]
      assert keys(hd(out["events"])["attributes"]) == ["kept"]
      assert keys(hd(out["links"])["attributes"]) == ["kept"]
    end

    test "attribute keys are capped" do
      result =
        span(attributes: [attribute(String.duplicate("k", 300), "v"), attribute("ok", "v")])
        |> sanitized_span()

      assert keys(result["attributes"]) == ["ok"]
    end

    test "a malformed parent span id is removed" do
      for bad <- ["short", String.duplicate("0", 16), String.duplicate("G", 16), 7] do
        result = span() |> Map.put("parentSpanId", bad) |> sanitized_span()
        refute Map.has_key?(result, "parentSpanId"), "kept #{inspect(bad)}"
      end

      parent = id(8)

      assert (span() |> Map.put("parentSpanId", parent) |> sanitized_span())["parentSpanId"] ==
               parent
    end

    test "a link with malformed ids is dropped" do
      good = %{"traceId" => id(16), "spanId" => id(8)}

      result =
        span()
        |> Map.put("links", [
          %{"traceId" => "short", "spanId" => id(8)},
          %{"traceId" => id(16), "spanId" => "zz"},
          %{"spanId" => id(8)},
          "not-a-map",
          good
        ])
        |> sanitized_span()

      assert [%{"traceId" => trace_id}] = result["links"]
      assert trace_id == good["traceId"]
    end

    test "kind and timestamps must be scalar" do
      result =
        span()
        |> Map.merge(%{
          "kind" => %{"a" => 1},
          "startTimeUnixNano" => %{"a" => 1},
          "endTimeUnixNano" => ["1"]
        })
        |> sanitized_span()

      refute Map.has_key?(result, "kind")
      refute Map.has_key?(result, "startTimeUnixNano")
      refute Map.has_key?(result, "endTimeUnixNano")
    end

    test "only the listed span fields survive" do
      result =
        span()
        |> Map.put("droppedAttributesCount", 9)
        |> Map.put("custom", "x")
        |> sanitized_span()

      refute Map.has_key?(result, "droppedAttributesCount")
      refute Map.has_key?(result, "custom")
    end

    test "trusted attributes are added after stripping" do
      result = sanitized_span(span(), %{"ash.test_key" => "from-server"})

      assert %{"key" => "ash.test_key", "value" => %{"stringValue" => "from-server"}} in result[
               "attributes"
             ]
    end

    test "a forged key cannot survive into the sink" do
      trace_id = id(16)

      payload([span(trace_id: trace_id, attributes: [attribute("ash.test_key", "stolen")])])
      |> request()
      |> call()

      assert TraceSink.by_test_key("stolen") == []
      assert TraceSink.trace(trace_id)
    end
  end

  describe "forwarding" do
    test "forwards the sanitized batch to the collector" do
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = read_body(conn)
        send(test_pid, {:forwarded, conn.request_path, Jason.decode!(body)})
        send_resp(conn, 200, "{}")
      end

      conn =
        payload([
          span(
            attributes: [
              attribute("ash.correlation_id", "forged"),
              attribute("ui.page.path", "/x")
            ]
          )
        ])
        |> request()
        |> call(collector_url: "http://collector.test/v1/traces", req_options: [plug: plug])

      assert conn.status == 200
      assert_receive {:forwarded, "/v1/traces", body}, 2_000
      refute inspect(body) =~ "forged"
    end

    test "a failing collector does not fail the request or stop later forwards" do
      test_pid = self()

      failing = fn _conn ->
        send(test_pid, :collector_called)
        raise "collector down"
      end

      conn =
        payload([span()])
        |> request()
        |> call(collector_url: "http://collector.test/v1/traces", req_options: [plug: failing])

      assert conn.status == 200
      assert_receive :collector_called, 2_000

      working = fn conn ->
        send(test_pid, :collector_recovered)
        send_resp(conn, 200, "{}")
      end

      conn =
        payload([span()])
        |> request()
        |> call(collector_url: "http://collector.test/v1/traces", req_options: [plug: working])

      assert conn.status == 200
      assert_receive :collector_recovered, 2_000
    end

    test "multi-byte text at the cap reaches the collector" do
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = read_body(conn)
        send(test_pid, {:forwarded, Jason.decode!(body)})
        send_resp(conn, 200, "{}")
      end

      conn =
        payload([span(name: String.duplicate("日本語", 1_000))])
        |> request()
        |> call(collector_url: "http://collector.test/v1/traces", req_options: [plug: plug])

      assert conn.status == 200
      assert_receive {:forwarded, %{"resourceSpans" => [_ | _]}}, 2_000
    end
  end

  describe "the client key" do
    defp limited(conn, key) do
      call(conn, rate_limit: 1, client_key: {__MODULE__, :client_key, [key]})
    end

    def client_key(_conn, key), do: key

    def raising_client_key(_conn), do: raise("no key")

    test "two clients behind one proxy get separate buckets" do
      one = "client-#{System.unique_integer([:positive])}"
      two = "client-#{System.unique_integer([:positive])}"

      assert (payload([span()]) |> request() |> limited(one)).status == 200
      assert (payload([span()]) |> request() |> limited(one)).status == 429
      assert (payload([span()]) |> request() |> limited(two)).status == 200
    end

    test "a raising client key falls back to the remote address rather than failing" do
      conn =
        payload([span()])
        |> request()
        |> call(rate_limit: 100_000, client_key: {__MODULE__, :raising_client_key, []})

      assert conn.status == 200
    end
  end
end
