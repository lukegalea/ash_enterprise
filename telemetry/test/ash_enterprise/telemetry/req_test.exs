defmodule AshEnterprise.Telemetry.ReqTest do
  use ExUnit.Case, async: true

  alias OpenTelemetry.Tracer

  import AshEnterprise.Telemetry.TraceHelpers

  require OpenTelemetry.Tracer

  defp adapter(test_pid) do
    fn request ->
      send(test_pid, {:headers, request.headers})
      {request, Req.Response.new(status: 200)}
    end
  end

  test "an outbound request carries the current trace" do
    key = test_key!()
    test_pid = self()

    Tracer.with_span "outbound.root" do
      Req.new(url: "http://example.test/x", adapter: adapter(test_pid), retry: false)
      |> AshEnterprise.Telemetry.Req.attach()
      |> Req.get!()
    end

    assert_received {:headers, %{"traceparent" => [traceparent]}}

    root = span_named(key, "outbound.root")

    root_hex =
      root.trace_id |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(32, "0")

    assert traceparent =~ root_hex
  end

  test "propagation can be turned off explicitly" do
    test_key!()
    test_pid = self()

    Tracer.with_span "no.propagation" do
      Req.new(url: "http://example.test/x", adapter: adapter(test_pid), retry: false)
      |> AshEnterprise.Telemetry.Req.attach(propagate_trace_headers: false)
      |> Req.get!()
    end

    assert_received {:headers, headers}
    refute Map.has_key?(headers, "traceparent")
  end
end
