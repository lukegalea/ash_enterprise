defmodule AshEnterprise.Telemetry.ReqTest do
  # `install` rewrites Req's global default options.
  use ExUnit.Case, async: false

  alias OpenTelemetry.Tracer

  import AshEnterprise.Telemetry.TraceHelpers

  require OpenTelemetry.Tracer

  defmodule Adapter do
    @moduledoc false
    # Answers with the status the test asked for and hands the test the headers sent.
    def run(request) do
      send(request.private.test_pid, {:headers, request.headers})
      {request, Req.Response.new(status: Map.get(request.private, :test_status, 200))}
    end
  end

  defp request(url \\ "http://api.example.test/v1/things?token=secret", status \\ 200) do
    Req.new(url: url, adapter: Adapter, retry: false)
    |> Req.Request.put_private(:test_pid, self())
    |> Req.Request.put_private(:test_status, status)
  end

  defp hex(id, size),
    do: id |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(size, "0")

  test "every request is a client span, with no attach at the call site" do
    key = test_key!()

    Tracer.with_span "outbound.root" do
      Req.get!(request())
    end

    assert_received {:headers, %{"traceparent" => [traceparent]}}

    root = span_named(key, "outbound.root")
    client = span_named(key, "GET")

    assert client.kind == :client
    assert client.parent_span_id == root.span_id
    assert attr(client, :"server.address") == "api.example.test"
    assert attr(client, :"server.port") == 80
    assert attr(client, :"http.request.method") == "GET"
    assert attr(client, :"http.response.status_code") == 200
    # No query: it carries keys and ids.
    assert attr(client, :"url.full") == "http://api.example.test/v1/things"

    # The downstream continues the client span, not its parent.
    assert traceparent == "00-#{hex(root.trace_id, 32)}-#{hex(client.span_id, 16)}-01"
  end

  test "attaching by hand as well gives one span" do
    key = test_key!()

    Tracer.with_span "attached.twice" do
      request()
      |> AshEnterprise.Telemetry.Req.attach()
      |> AshEnterprise.Telemetry.Req.attach()
      |> Req.get!()
    end

    assert key |> spans() |> Enum.count(&(&1.name == "GET")) == 1
  end

  test "a 4xx or 5xx answer is an error on the client span" do
    key = test_key!()

    Tracer.with_span "error.root" do
      Req.get!(request("https://api.example.test/x", 503))
    end

    client = span_named(key, "GET")
    assert attr(client, :"error.type") == "503"
    assert attr(client, :"server.port") == 443
    assert client.status_code == :error
  end

  test "propagation can be turned off for a client or a request" do
    test_key!()

    Tracer.with_span "no.propagation" do
      request()
      |> AshEnterprise.Telemetry.Req.attach(propagate_trace_headers: false)
      |> Req.get!()

      Req.get!(request(), trace_propagation: false)
    end

    assert_received {:headers, first}
    assert_received {:headers, second}
    refute Map.has_key?(first, "traceparent")
    refute Map.has_key?(second, "traceparent")
  end

  test "install keeps the application's other defaults and adds the plugin once" do
    original = Application.get_env(:req, :default_options)

    try do
      Application.put_env(:req, :default_options, retry: false, plugins: [SomeOther])
      :ok = AshEnterprise.Telemetry.Req.install()
      :ok = AshEnterprise.Telemetry.Req.install()

      defaults = Application.get_env(:req, :default_options)
      assert defaults[:retry] == false
      assert defaults[:plugins] == [SomeOther, AshEnterprise.Telemetry.Req]
    after
      Application.put_env(:req, :default_options, original)
    end
  end
end
