defmodule AshBrowserTests.BackendsTest do
  use ExUnit.Case, async: true

  alias AshBrowserTests.Backend
  alias AshBrowserTests.Backend.GlitchTip
  alias AshBrowserTests.Backend.SigNoz
  alias AshBrowserTests.Backend.TraceSink
  alias AshBrowserTests.Fake
  alias AshBrowserTests.Span
  alias AshBrowserTests.Trace

  @trace "a3dd58b752edaf1c2f55c78672684cc3"

  # The shape of a real `query_range` v5 response from SigNoz 0.149, with the
  # application's own names removed.
  defp signoz_response(rows) do
    %{
      "status" => "success",
      "data" => %{
        "type" => "raw",
        "data" => %{"results" => [%{"queryName" => "A", "rows" => rows}]}
      }
    }
  end

  defp signoz_row(overrides) do
    %{
      "data" =>
        Map.merge(
          %{
            "attributes" => %{"ash.correlation_id" => "c1", "ash.action" => "read"},
            "events" => [],
            "links" => [],
            "has_error" => false,
            "kind_string" => "Client",
            "name" => "repo.query",
            "parent_span_id" => "cbdb27b9911e54b8",
            "span_id" => "ac50658115201001",
            "status_code_string" => "Unset",
            "status_message" => "",
            "trace_id" => @trace
          },
          overrides
        ),
      "timestamp" => "2026-11-09T19:25:58.591011832Z"
    }
  end

  defp fake_signoz(rows) do
    fake = start_supervised!(Fake)
    Fake.stub(fake, "POST", "/api/v5/query_range", json: signoz_response(rows))
    fake
  end

  describe "SigNoz" do
    test "queries by trace id and normalizes rows" do
      fake = fake_signoz([signoz_row(%{})])

      assert {:ok, [span]} =
               Backend.spans_for({:trace_id, @trace}, 1_000,
                 backend: SigNoz,
                 url: Fake.url(fake),
                 api_key: "secret"
               )

      assert span.trace_id == @trace
      assert span.parent_span_id == "cbdb27b9911e54b8"
      assert span.kind == :client
      assert span.status == :unset
      assert span.source == :signoz

      assert [request] = Fake.requests(fake)
      assert request.headers["signoz-api-key"] == "secret"

      assert get_in(request.json, [
               "compositeQuery",
               "queries",
               Access.at(0),
               "spec",
               "filter",
               "expression"
             ]) == "trace_id = '#{@trace}'"
    end

    test "a test key filters on the attribute" do
      assert SigNoz.expression("some-key") == "ash.test_key = 'some-key'"

      assert SigNoz.expression({:trace_id, "ab"}, only_errors: true) ==
               "trace_id = 'ab' AND hasError = true"
    end

    test "an exception is read from the row's events, however they are encoded" do
      event = %{
        "name" => "exception",
        "attributes" => %{"exception.type" => "RuntimeError", "exception.message" => "boom"}
      }

      fake =
        fake_signoz([
          signoz_row(%{"has_error" => true, "events" => [event]}),
          signoz_row(%{
            "span_id" => "2",
            "has_error" => true,
            "events" => [Jason.encode!(event)],
            "name" => "other"
          })
        ])

      assert {:ok, spans} =
               SigNoz.spans_for({:trace_id, @trace}, url: Fake.url(fake), only_errors: true)

      assert Enum.all?(spans, &(&1.status == :error))
      assert Trace.assert_exception(spans, "RuntimeError").name == "repo.query"
      assert Trace.assert_exception(spans, type: "RuntimeError", span: "other").name == "other"
    end

    test "a non-200 is an error and a missing span list is empty" do
      fake = start_supervised!(Fake)
      Fake.stub(fake, "POST", "/api/v5/query_range", status: 403, json: %{"error" => "no"})

      assert {:error, {:http_status, 403, _body}} = SigNoz.spans_for("k", url: Fake.url(fake))

      fake2 = start_supervised!({Fake, []}, id: :two)
      Fake.stub(fake2, "POST", "/api/v5/query_range", json: %{"status" => "success"})
      assert {:ok, []} = SigNoz.spans_for("k", url: Fake.url(fake2))
    end
  end

  describe "GlitchTip" do
    defp issues do
      [
        %{
          "id" => 7,
          "title" => "RuntimeError: boom",
          "count" => "2",
          "metadata" => %{"type" => "RuntimeError", "value" => "boom"}
        }
      ]
    end

    test "searches by the trace id tag and returns an exception-bearing span" do
      fake = start_supervised!(Fake)
      Fake.stub(fake, "GET", "/api/0/organizations/org/issues/", json: issues())

      assert {:ok, [span]} =
               GlitchTip.spans_for({:trace_id, @trace},
                 url: Fake.url(fake),
                 organization: "org",
                 token: "tok"
               )

      assert span.status == :error
      assert Trace.assert_exception([span], "RuntimeError").span_id == "7"

      assert [request] = Fake.requests(fake)
      assert request.query == URI.encode_query(query: "trace_id:#{@trace}")
      assert request.headers["authorization"] == "Bearer tok"
    end

    test "a test key cannot be searched" do
      assert {:error, {:unsupported_key, "k"}} =
               GlitchTip.spans_for("k", url: "", organization: "o")
    end
  end

  describe "the TraceSink backend" do
    test "normalizes ids to hex and attributes to string keys" do
      span =
        TraceSink.normalize(%{
          trace_id: 255,
          span_id: 16,
          parent_span_id: 0,
          name: "n",
          attributes: %{"a" => 1, b: 2},
          events: [%{name: "e", attributes: %{}}],
          links: [%{trace_id: 1, span_id: 2}]
        })

      assert span.trace_id == String.pad_leading("ff", 32, "0")
      assert span.span_id == String.pad_leading("10", 16, "0")
      assert span.parent_span_id == nil
      assert span.attributes == %{"a" => 1, "b" => 2}
      assert [%{trace_id: _}] = span.links
      assert Span.matches?(span, name: "n")
    end
  end

  describe "polling" do
    defmodule Flaky do
      @behaviour AshBrowserTests.Backend

      @impl true
      def spans_for(_key, opts) do
        agent = Keyword.fetch!(opts, :agent)
        count = Agent.get_and_update(agent, &{&1, &1 + 1})
        if count < 2, do: {:ok, []}, else: {:ok, [:span]}
      end
    end

    test "polls until a span appears or the timeout ends" do
      agent = start_supervised!({Agent, fn -> 0 end})
      assert {:ok, [:span]} = Backend.spans_for("k", 1_000, backend: Flaky, agent: agent)
    end

    test "an empty result after the timeout is a success" do
      agent = start_supervised!({Agent, fn -> -100 end})
      assert {:ok, []} = Backend.spans_for("k", 30, backend: Flaky, agent: agent)
    end
  end
end
