defmodule AshBrowserTests.TraceBrowserTest do
  @moduledoc false
  # Real browser, real LiveView, real Postgres: the chain assertions run over spans
  # that Chromium and the server actually produced.
  use AshBrowserTests.Case, async: true

  alias AshBrowserTests.Fake
  alias AshBrowserTests.Fixture.Endpoint
  alias AshBrowserTests.Span
  alias AshBrowserTests.TestKey
  alias AshBrowserTests.Trace

  defp signed_in(conn) do
    sign_in(conn, %{"user" => "alice"}, Endpoint.session_options())
  end

  test "browser event -> handle_event -> Ash action -> query", %{conn: conn, test_key: key} do
    conn
    |> signed_in()
    |> visit("/widgets")
    |> assert_connected()
    |> click_button("Create widget")

    [browser, event, action, query] =
      Trace.assert_chain(key, [
        Trace.browser_event(name: "create"),
        Trace.handle_event(),
        Trace.ash_action(action: :create),
        Trace.query()
      ])

    assert browser.attributes["ui.control.label"] == "Create widget"
    assert event.name =~ "handle_event#create"
    assert action.attributes["ash.action"] == "create"
    assert query.attributes["db.system"] == "postgresql"
    assert Map.get(event.attributes, TestKey.attribute()) == key
  end

  test "the connected mount is under the browser's connect span and carries the test key", %{
    conn: conn,
    test_key: key
  } do
    conn |> signed_in() |> visit("/whoami") |> assert_connected() |> flush_browser_spans()

    [_connect, mount] =
      Trace.assert_chain(key, [Trace.browser_connect(), Trace.live_mount()], direct: true)

    assert mount.attributes[TestKey.attribute()] == key
  end

  test "one correlation id across the handle_event tree", %{conn: conn, test_key: key} do
    conn
    |> signed_in()
    |> visit("/widgets")
    |> assert_connected()
    |> click_button("Create widget")

    id = Trace.assert_one_correlation(key, Trace.handle_event(), min_spans: 3)
    assert is_binary(id)
  end

  test "a job is a new trace linked to the producer span in the request trace", %{
    conn: conn,
    test_key: key
  } do
    conn
    |> signed_in()
    |> visit("/widgets?oban=1")
    |> assert_connected()
    |> click_button("Create widget")

    producer = Trace.assert_span(key, Trace.job_producer())
    assert %{success: 1} = Oban.drain_queue(queue: :default)

    {linked_producer, consumer} =
      Trace.assert_linked(key, Trace.job_producer(), Trace.job_consumer())

    assert linked_producer.span_id == producer.span_id
    assert consumer.trace_id != linked_producer.trace_id

    # The request and the job share the correlation id across the two traces.
    assert consumer.attributes["ash.correlation_id"] ==
             producer.attributes["ash.correlation_id"]
  end

  test "an outbound call reaches a fake with the propagated trace id", %{
    conn: conn,
    test_key: key
  } do
    fake = start_supervised!(Fake)
    Fake.stub(fake, "POST", "/called", status: 201, json: %{"ok" => true})

    conn
    |> signed_in()
    |> visit("/widgets?fake=#{URI.encode_www_form(Fake.url(fake))}")
    |> assert_connected()
    |> click_button("Create widget")

    [_browser, event, http] =
      Trace.assert_chain(key, [
        Trace.browser_event(),
        Trace.handle_event(),
        [kind: :client, attributes: %{"http.request.method" => "POST"}]
      ])

    assert [request] = Fake.requests(fake, "/called")
    assert request.json == %{"from" => "fixture"}
    assert request.trace_id == event.trace_id
    assert request.trace_id == http.trace_id
  end

  @tag allow_browser_failures: true
  test "a crash in handle_event is an exception event on its span", %{conn: conn, test_key: key} do
    conn |> signed_in() |> visit("/widgets") |> assert_connected() |> click_button("Crash")

    span =
      Trace.assert_exception(key,
        message: ~r/fixture crash/,
        span: Trace.handle_event()
      )

    assert span.status == :error
  end

  test "a broken parent chain fails the assertion against real spans", %{
    conn: conn,
    test_key: key
  } do
    conn
    |> signed_in()
    |> visit("/widgets")
    |> assert_connected()
    |> click_button("Create widget")

    Trace.assert_chain(key, [Trace.handle_event(), Trace.ash_action(action: :create)])

    # Remove the handle_event span: its children lose their parent.
    spans = Trace.spans(key) |> Enum.reject(&Span.matches?(&1, Trace.handle_event()))

    assert_raise ExUnit.AssertionError, ~r/no chain of 3 spans/, fn ->
      Trace.assert_chain(spans, [
        Trace.browser_event(),
        Trace.handle_event(),
        Trace.ash_action(action: :create)
      ])
    end
  end
end
