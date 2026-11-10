defmodule AshEnterprise.Telemetry.BanditSpansTest do
  use ExUnit.Case, async: true

  alias AshEnterprise.Telemetry
  alias AshEnterprise.Telemetry.TraceSink

  import AshEnterprise.Telemetry.TraceHelpers

  @moduletag :capture_log

  setup do
    server =
      start_supervised!(
        {Bandit,
         plug: AshEnterprise.Telemetry.BanditProbePlug, ip: :loopback, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, base: "http://127.0.0.1:#{port}"}
  end

  defp get(url, headers \\ []) do
    Req.get!(url, headers: headers, retry: false, decode_json: [])
  end

  defp request_span(trace_id) do
    trace = eventually(fn -> TraceSink.trace(trace_id) end)
    Enum.find(trace.spans, &(&1.kind == :server))
  end

  defp attribute(span, name), do: span.attributes[name] || span.attributes[to_string(name)]

  describe "a client's trace headers" do
    test "do not make the request part of the client's trace", %{base: base} do
      tp = traceparent("01")
      body = Jason.decode!(get(base <> "/probe", traceparent: tp.header).body)

      refute body["trace_id"] == tp.hex_trace
    end

    test "are kept as a link, for joining a trace on purpose", %{base: base} do
      tp = traceparent("01")
      body = Jason.decode!(get(base <> "/probe", traceparent: tp.header).body)

      assert [%{trace_id: trace_id}] = request_span(body["trace_id"]).links
      assert trace_id == tp.trace_id
    end

    test "cannot make the request unrecorded with the -00 flag", %{base: base} do
      tp = traceparent("00")
      body = Jason.decode!(get(base <> "/probe", traceparent: tp.header).body)

      assert body["recording"] == true
      assert request_span(body["trace_id"])
    end

    test "client baggage does not enter the request's context", %{base: base} do
      body = Jason.decode!(get(base <> "/probe", baggage: "tenant=forged").body)

      assert body["baggage"] == []
    end
  end

  test "a request with no trace headers has no links", %{base: base} do
    body = Jason.decode!(get(base <> "/probe").body)
    assert request_span(body["trace_id"]).links == []
  end

  test "public endpoint is the default and internal callers can opt out" do
    assert Telemetry.bandit_options(public_endpoint: true) == [public_endpoint: true]
    assert Telemetry.bandit_options(public_endpoint: false) == [public_endpoint: false]

    assert Telemetry.bandit_options(public_endpoint: {Mod, :public?, []}) == [
             public_endpoint_fn: {Mod, :public?, []}
           ]
  end

  test "setup defaults to a public endpoint" do
    [handler] =
      [:bandit, :request, :start]
      |> :telemetry.list_handlers()
      |> Enum.filter(&(&1.id == {AshEnterprise.Telemetry.BanditSpans, :span}))

    assert handler.config.public_endpoint == true
  end

  describe "the query string" do
    test "never reaches the span with its values", %{base: base} do
      body = Jason.decode!(get(base <> "/probe?reset_token=abc123&_csrf_token=zzz999").body)

      span = request_span(body["trace_id"])
      refute inspect(span) =~ "abc123"
      refute inspect(span) =~ "zzz999"
      assert attribute(span, :"url.query") == "reset_token=[Filtered]&_csrf_token=[Filtered]"
    end

    test "an empty query adds no attribute", %{base: base} do
      body = Jason.decode!(get(base <> "/probe").body)
      assert attribute(request_span(body["trace_id"]), :"url.query") == nil
    end
  end

  describe "a crash in the request" do
    defp exception_attributes(key_value) do
      span =
        eventually(fn ->
          Enum.find(TraceSink.last(500), fn trace ->
            Enum.any?(trace.spans, &(attribute(&1, :"url.path") == key_value))
          end)
        end)
        |> Map.fetch!(:spans)
        |> Enum.find(&(attribute(&1, :"url.path") == key_value))

      assert [%{name: "exception", attributes: attributes}] = eventually(fn -> span.events end)
      attributes
    end

    test "records the arity, not the arguments", %{base: base} do
      path = "/clause-#{System.unique_integer([:positive])}"
      assert get(base <> path).status == 500

      attributes = exception_attributes(path)
      refute attributes[:"exception.stacktrace"] =~ "plug-arg-secret"
      assert attributes[:"exception.stacktrace"] =~ "only_never/1"
    end

    test "does not print the value in a MatchError message", %{base: base} do
      path = "/match-#{System.unique_integer([:positive])}"
      assert get(base <> path).status == 500

      refute exception_attributes(path)[:"exception.message"] =~ "plug-match-secret"
    end
  end
end
