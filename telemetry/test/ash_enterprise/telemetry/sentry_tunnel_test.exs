defmodule AshEnterprise.Telemetry.SentryTunnelTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias AshEnterprise.Telemetry.SentryTunnel

  @path "/sentry/tunnel"
  @host "app.example.test"
  @dsn "https://abc123@errors.example.test/7"

  defp event(extra \\ %{}), do: Map.merge(%{"event_id" => "e1", "message" => "boom"}, extra)

  defp envelope(items, dsn \\ @dsn) do
    header = Jason.encode!(%{"event_id" => "e1", "dsn" => dsn, "trace" => %{"public_key" => "x"}})

    lines =
      Enum.flat_map(items, fn {type, payload} ->
        body = if is_binary(payload), do: payload, else: Jason.encode!(payload)
        [Jason.encode!(%{"type" => type, "length" => byte_size(body)}), body]
      end)

    Enum.join([header | lines], "\n")
  end

  defp request(body, opts \\ []) do
    :post
    |> conn(@path, body)
    |> then(&%{&1 | req_headers: [{"host", @host} | &1.req_headers]})
    |> put_req_header(
      "content-type",
      Keyword.get(opts, :content_type, "text/plain;charset=UTF-8")
    )
    |> then(fn conn ->
      case Keyword.get(opts, :origin, "https://#{@host}") do
        nil -> conn
        origin -> put_req_header(conn, "origin", origin)
      end
    end)
    |> Map.put(:remote_ip, {10, 1, 0, rem(System.unique_integer([:positive]), 250)})
  end

  defp forwarding(test_pid) do
    fn conn ->
      {:ok, body, conn} = read_body(conn)
      send(test_pid, {:forwarded, conn.host, conn.request_path, conn.query_string, body, conn})
      send_resp(conn, 200, "{}")
    end
  end

  defp call(conn, opts \\ []) do
    defaults = [enabled: true, dsns: [@dsn], req_options: [plug: forwarding(self())]]
    SentryTunnel.call(conn, SentryTunnel.init(Keyword.merge(defaults, opts)))
  end

  defp forwarded_items do
    assert_receive {:forwarded, _host, _path, _query, body, _conn}, 2_000
    [_header | rest] = String.split(body, "\n")

    rest
    |> Enum.chunk_every(2)
    |> Enum.map(fn [header, item] -> {Jason.decode!(header), item} end)
  end

  describe "off unless configured" do
    test "with no configuration the plug passes through" do
      conn =
        envelope([{"event", event()}]) |> request() |> SentryTunnel.call(SentryTunnel.init([]))

      refute conn.halted
      assert conn.status == nil
    end

    test "other paths pass through" do
      conn = :post |> conn("/elsewhere", "x") |> call()
      refute conn.halted
    end

    test "enabled with no DSN admits nothing" do
      assert (envelope([{"event", event()}]) |> request() |> call(dsns: [])).status == 403
    end
  end

  describe "rejections" do
    test "only POST is accepted" do
      assert (:get |> conn(@path) |> call()).status == 405
    end

    test "a cross-origin or originless request is rejected" do
      body = envelope([{"event", event()}])
      assert (body |> request(origin: "https://evil.test") |> call()).status == 403
      assert (body |> request(origin: nil) |> call()).status == 403
    end

    test "a wrong content type or an encoded body is rejected" do
      body = envelope([{"event", event()}])
      assert (body |> request(content_type: "application/json") |> call()).status == 415

      conn = body |> request() |> put_req_header("content-encoding", "gzip") |> call()
      assert conn.status == 415
    end

    test "a body over the cap is rejected" do
      assert (String.duplicate("x", 262_145) |> request() |> call()).status == 413
    end

    test "a DSN outside the allowlist is rejected and nothing is forwarded" do
      for dsn <- [
            "https://abc123@evil.test/7",
            "https://other@errors.example.test/7",
            "https://abc123@errors.example.test/8",
            "http://127.0.0.1:9/7"
          ] do
        conn = envelope([{"event", event()}], dsn) |> request() |> call()
        assert conn.status == 403, "admitted #{dsn}"
      end

      refute_receive {:forwarded, _, _, _, _, _}, 50
    end

    test "a malformed envelope is rejected" do
      for body <- [
            "not json",
            "{}",
            ~s({"dsn":7}),
            ~s({"dsn":"#{@dsn}"}\n{"type":"event"}\nnot-json)
          ] do
        assert (body |> request() |> call()).status in [400, 403], "accepted #{body}"
      end
    end

    test "the rate limit applies per client, using the client key" do
      opts = [
        rate_limit: 1,
        client_key: {__MODULE__, :client_key, ["c-#{System.unique_integer()}"]}
      ]

      body = envelope([{"event", event()}])

      assert (body |> request() |> call(opts)).status == 200
      assert (body |> request() |> call(opts)).status == 429
    end

    def client_key(_conn, key), do: key

    test "the global rate limit applies" do
      body = envelope([{"event", event()}])

      assert (body |> request() |> call(global_rate_limit: 0)).status == 429
    end
  end

  describe "forwarding" do
    test "goes to the configured host's envelope endpoint, with the DSN's key" do
      assert (envelope([{"event", event()}]) |> request() |> call()).status == 200

      assert_receive {:forwarded, "errors.example.test", "/api/7/envelope/", "sentry_key=abc123",
                      _body, conn},
                     2_000

      assert get_req_header(conn, "content-type") == ["application/x-sentry-envelope"]
    end

    test "a path-prefixed DSN keeps its prefix" do
      dsn = "https://abc123@errors.example.test/glitch/7"

      envelope([{"event", event()}], dsn) |> request() |> call(dsns: [dsn])

      assert_receive {:forwarded, _, "/glitch/api/7/envelope/", _, _, _}, 2_000
    end

    test "a failing backend does not fail the request" do
      plug = fn _conn -> raise "down" end

      conn = envelope([{"event", event()}]) |> request() |> call(req_options: [plug: plug])
      assert conn.status == 200
    end
  end

  describe "what is forwarded" do
    defp forwarded_event(payload) do
      assert (envelope([{"event", payload}]) |> request() |> call()).status == 200
      assert [{%{"type" => "event"}, item}] = forwarded_items()
      Jason.decode!(item)
    end

    test "client-supplied identity and server-asserted tags are removed" do
      result =
        forwarded_event(
          event(%{
            "user" => %{"id" => "forged", "email" => "a@b.test", "ip_address" => "1.1.1.1"},
            "tags" => %{
              "correlation_id" => "forged",
              "ash.actor" => "forged",
              "audit.user" => "forged",
              "trace_id" => "kept",
              "page" => "kept"
            },
            "extra" => %{"ash.tenant" => "forged", "note" => "kept"}
          })
        )

      refute Map.has_key?(result, "user")
      refute inspect(result) =~ "forged"
      assert result["tags"] == %{"trace_id" => "kept", "page" => "kept"}
      assert result["extra"] == %{"note" => "kept"}
    end

    test "urls lose their query, and request headers go" do
      result =
        forwarded_event(
          event(%{
            "request" => %{
              "url" => "https://app.test/reset?token=hunter2",
              "headers" => %{"Referer" => "https://app.test/?token=hunter2"}
            },
            "breadcrumbs" => [
              %{
                "category" => "navigation",
                "data" => %{"from" => "/a?token=hunter2", "to" => "/b#hunter2"}
              },
              %{
                "category" => "fetch",
                "data" => %{"url" => "/x?token=hunter2", "status_code" => 200}
              }
            ]
          })
        )

      refute inspect(result) =~ "hunter2"
      assert result["request"] == %{"url" => "https://app.test/reset"}

      assert [%{"data" => %{"from" => "/a", "to" => "/b"}}, %{"data" => %{"url" => "/x"}} | _] =
               result["breadcrumbs"]
    end

    test "the item length is the scrubbed payload's, and the header keeps only known fields" do
      envelope([{"event", event(%{"user" => %{"id" => "forged"}})}]) |> request() |> call()

      assert_receive {:forwarded, _, _, _, body, _}, 2_000
      [header, item_header, item] = String.split(body, "\n")

      assert Jason.decode!(item_header)["length"] == byte_size(item)
      assert Jason.decode!(header) |> Map.keys() |> Enum.sort() == ["dsn", "event_id"]
    end

    test "only event items are forwarded" do
      body =
        envelope([
          {"attachment", "binary\nwith newline"},
          {"event", event()},
          {"replay_event", %{"x" => 1}},
          {"client_report", %{"discarded_events" => []}}
        ])

      assert (body |> request() |> call()).status == 200
      assert [{%{"type" => "event"}, _item}] = forwarded_items()
    end

    test "an envelope with no event is accepted and not forwarded" do
      assert (envelope([{"client_report", %{"discarded_events" => []}}])
              |> request()
              |> call()).status == 200

      refute_receive {:forwarded, _, _, _, _, _}, 50
    end
  end
end
