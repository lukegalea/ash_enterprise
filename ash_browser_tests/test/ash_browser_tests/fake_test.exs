defmodule AshBrowserTests.FakeTest do
  use ExUnit.Case, async: true

  alias AshBrowserTests.Fake
  alias AshBrowserTests.Fake.DSN
  alias AshBrowserTests.Fake.LLM

  test "records method, path, headers, json and the propagated traceparent" do
    fake = start_supervised!(Fake)
    trace = String.duplicate("a", 32)
    traceparent = "00-#{trace}-#{String.duplicate("b", 16)}-01"

    Req.post!(Fake.url(fake) <> "/thing?x=1",
      json: %{"a" => 1},
      headers: [{"traceparent", traceparent}, {"x-custom", "y"}],
      retry: false
    )

    assert [request] = Fake.requests(fake)
    assert request.method == "POST"
    assert request.path == "/thing"
    assert request.query == "x=1"
    assert request.json == %{"a" => 1}
    assert request.trace_id == trace
    assert request.headers["x-custom"] == "y"
  end

  test "stubs answer by method and path, later stubs first" do
    fake = start_supervised!(Fake)
    Fake.stub(fake, "GET", "/a", status: 201, body: "first")
    Fake.stub(fake, "GET", "/a", status: 418, json: %{"teapot" => true})

    response = Req.get!(Fake.url(fake) <> "/a", retry: false)
    assert response.status == 418
    assert response.body == %{"teapot" => true}

    assert Req.get!(Fake.url(fake) <> "/other", retry: false).status == 200
    assert Fake.requests(fake, "/a") |> length() == 1
  end

  test "two fakes record independently" do
    a = start_supervised!(Fake)
    b = start_supervised!({Fake, []}, id: :second)
    Req.get!(Fake.url(a) <> "/a", retry: false)
    assert [_] = Fake.requests(a)
    assert Fake.requests(b) == []
  end

  test "a request from a process the test did not spawn is still recorded" do
    fake = start_supervised!(Fake)
    url = Fake.url(fake)
    spawn(fn -> Req.get!(url <> "/from-elsewhere", retry: false) end)

    assert eventually(fn -> Fake.requests(fake, "/from-elsewhere") != [] end)
  end

  describe "LLM" do
    test "scripted replies on the OpenAI path, then the default" do
      llm = start_supervised!({LLM, default_reply: "default"})
      LLM.enqueue(llm, "scripted")

      body = %{"model" => "m", "messages" => [%{"role" => "user", "content" => "hi"}]}

      first = Req.post!(Fake.url(llm) <> "/v1/chat/completions", json: body, retry: false).body
      assert get_in(first, ["choices", Access.at(0), "message", "content"]) == "scripted"

      second = Req.post!(Fake.url(llm) <> "/v1/chat/completions", json: body, retry: false).body
      assert get_in(second, ["choices", Access.at(0), "message", "content"]) == "default"

      assert [%{json: %{"model" => "m"}}, _] = Fake.requests(llm, "/v1/chat/completions")
    end

    test "the Anthropic messages path" do
      llm = start_supervised!(LLM)
      LLM.enqueue(llm, "hello")

      response = Req.post!(Fake.url(llm) <> "/v1/messages", json: %{"model" => "m"}, retry: false)
      assert [%{"type" => "text", "text" => "hello"}] = response.body["content"]
    end

    test "streaming comes back as server-sent events" do
      llm = start_supervised!(LLM)
      LLM.enqueue(llm, "streamed")

      response =
        Req.post!(Fake.url(llm) <> "/v1/chat/completions",
          json: %{"model" => "m", "stream" => true},
          retry: false,
          decode_body: false
        )

      assert response.headers["content-type"] == ["text/event-stream"]
      assert response.body =~ "streamed"
      assert response.body =~ "[DONE]"
    end

    test "embeddings" do
      llm = start_supervised!(LLM)

      response =
        Req.post!(Fake.url(llm) <> "/v1/embeddings",
          json: %{"model" => "m", "input" => ["a", "b"]},
          retry: false
        )

      assert length(response.body["data"]) == 2
    end
  end

  describe "DSN" do
    defp envelope(event) do
      item = Jason.encode!(event)

      [
        Jason.encode!(%{"event_id" => event["event_id"]}),
        Jason.encode!(%{"type" => "event", "length" => byte_size(item)}),
        item,
        Jason.encode!(%{"type" => "attachment"}),
        "attachment body"
      ]
      |> Enum.join("\n")
    end

    test "parses the event out of an envelope, including the trace tag" do
      fake = start_supervised!(DSN)

      event = %{
        "event_id" => "abc123",
        "level" => "error",
        "tags" => %{"trace_id" => "deadbeef", "correlation_id" => "c1"},
        "exception" => %{"values" => [%{"type" => "RuntimeError", "value" => "boom"}]}
      }

      Req.post!(Fake.url(fake) <> "/api/1/envelope/",
        body: envelope(event),
        headers: [{"x-sentry-auth", "Sentry sentry_key=public"}],
        retry: false
      )

      assert [parsed] = DSN.events(fake)
      assert parsed.event_id == "abc123"
      assert parsed.trace_id == "deadbeef"
      assert parsed.exception_type == "RuntimeError"
      assert parsed.exception_value == "boom"
      assert parsed.tags["correlation_id"] == "c1"
    end

    test "dsn/1 is a usable DSN pointing at the fake" do
      fake = start_supervised!(DSN)
      assert DSN.dsn(fake) == "http://public@127.0.0.1:#{Fake.port(fake)}/1"
    end

    test "a gzipped envelope is decoded" do
      fake = start_supervised!(DSN)
      event = %{"event_id" => "gz", "exception" => %{"values" => []}}

      Req.post!(Fake.url(fake) <> "/api/1/envelope/",
        body: :zlib.gzip(envelope(event)),
        headers: [{"content-encoding", "gzip"}],
        retry: false
      )

      assert [%{event_id: "gz"}] = DSN.events(fake)
    end
  end

  defp eventually(fun, attempts \\ 100) do
    case fun.() do
      true ->
        true

      _falsy when attempts > 0 ->
        Process.sleep(20)
        eventually(fun, attempts - 1)

      _falsy ->
        false
    end
  end
end
