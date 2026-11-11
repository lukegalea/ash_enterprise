defmodule AshBrowserTests.TraceTest do
  use ExUnit.Case, async: true

  require OpenTelemetry.Tracer

  alias AshBrowserTests.Backend
  alias AshBrowserTests.Span
  alias AshBrowserTests.TestKey
  alias AshBrowserTests.Trace

  defp span(name, opts) do
    struct!(
      Span,
      [trace_id: "t", span_id: name, name: name] ++ opts
    )
  end

  defp chain do
    [
      span("browser", attributes: %{"ui.page.path" => "/x", "ui.event.name" => "go"}),
      span("event", parent_span_id: "browser"),
      span("action", parent_span_id: "event", attributes: %{"ash.action" => "create"}),
      span("query", parent_span_id: "action", attributes: %{"db.system" => "postgresql"})
    ]
  end

  describe "assert_chain" do
    test "follows a parent chain" do
      assert [_a, _b, _c, _d] =
               Trace.assert_chain(chain(), ["browser", "event", "action", "query"])
    end

    test "fails when a link is missing, naming the broken step" do
      spans = Enum.reject(chain(), &(&1.name == "event"))

      assert_raise ExUnit.AssertionError, ~r/reached step 1.*"event"/s, fn ->
        Trace.assert_chain(spans, ["browser", "event", "action"])
      end
    end

    test "a parent that is merely present in the list does not count" do
      spans = [
        span("a", []),
        span("b", parent_span_id: "not-a"),
        span("not-a", [])
      ]

      assert_raise ExUnit.AssertionError, ~r/no chain/, fn ->
        Trace.assert_chain(spans, ["a", "b"])
      end
    end

    test "a same-named span in another trace is not a parent" do
      spans = [
        span("root", trace_id: "one"),
        span("root", trace_id: "two"),
        span("child", trace_id: "two", parent_span_id: "other-root")
      ]

      assert_raise ExUnit.AssertionError, ~r/no chain/, fn ->
        Trace.assert_chain(spans, ["root", "child"])
      end
    end

    test "direct: true rejects a skipped level" do
      assert_raise ExUnit.AssertionError, fn ->
        Trace.assert_chain(chain(), ["browser", "action"], direct: true)
      end

      assert [_a, _b] = Trace.assert_chain(chain(), ["browser", "event"], direct: true)
    end

    test "the named matchers select the expected spans" do
      assert [_, _, _, _] =
               Trace.assert_chain(chain(), [
                 Trace.browser_event(name: "go"),
                 [name: "event"],
                 Trace.ash_action(action: :create),
                 Trace.query()
               ])
    end
  end

  describe "assert_linked" do
    defp producer(extra \\ []),
      do:
        struct!(Span, [trace_id: "req", span_id: "send", name: "send", kind: :producer] ++ extra)

    test "passes for a consumer linked to a producer in another trace" do
      consumer =
        span("job",
          trace_id: "job-trace",
          kind: :consumer,
          links: [%{trace_id: "req", span_id: "send"}]
        )

      assert {%{name: "send"}, %{name: "job"}} =
               Trace.assert_linked([producer(), consumer], "send", "job")
    end

    test "fails with no link" do
      consumer = span("job", trace_id: "job-trace", kind: :consumer)

      assert_raise ExUnit.AssertionError, ~r/not linked|no consumer/, fn ->
        Trace.assert_linked([producer(), consumer], "send", "job")
      end
    end

    test "fails when the link points at a different span" do
      consumer =
        span("job",
          trace_id: "job-trace",
          kind: :consumer,
          links: [%{trace_id: "req", span_id: "another"}]
        )

      assert_raise ExUnit.AssertionError, fn ->
        Trace.assert_linked([producer(), consumer], "send", "job")
      end
    end

    test "fails for a link inside the same trace" do
      consumer =
        span("job",
          trace_id: "req",
          kind: :consumer,
          links: [%{trace_id: "req", span_id: "send"}]
        )

      assert_raise ExUnit.AssertionError, fn ->
        Trace.assert_linked([producer(), consumer], "send", "job")
      end
    end
  end

  describe "assert_one_correlation" do
    defp with_correlation(span, id) do
      %{span | attributes: Map.put(span.attributes, "ash.correlation_id", id)}
    end

    test "passes when the tree shares one id" do
      spans =
        chain()
        |> Enum.drop(1)
        |> Enum.map(&with_correlation(&1, "c1"))

      assert "c1" = Trace.assert_one_correlation(spans, "event", min_spans: 3)
    end

    test "fails on two ids" do
      [event, action, query] = chain() |> Enum.drop(1)

      assert_raise ExUnit.AssertionError, ~r/expected one/, fn ->
        Trace.assert_one_correlation(
          [
            with_correlation(event, "c1"),
            with_correlation(action, "c2"),
            with_correlation(query, "c1")
          ],
          "event"
        )
      end
    end

    test "fails when one span has no id" do
      [event, action, query] = chain() |> Enum.drop(1)

      assert_raise ExUnit.AssertionError, fn ->
        Trace.assert_one_correlation(
          [with_correlation(event, "c1"), action, with_correlation(query, "c1")],
          "event"
        )
      end
    end

    test "fails on a single span unless min_spans allows it" do
      lone = span("event", attributes: %{"ash.correlation_id" => "c1"})

      assert_raise ExUnit.AssertionError, ~r/fewer than 2 spans/, fn ->
        Trace.assert_one_correlation([lone], "event")
      end

      assert "c1" = Trace.assert_one_correlation([lone], "event", min_spans: 1)
    end
  end

  describe "assert_exception" do
    @exception %{
      name: "exception",
      attributes: %{"exception.type" => "RuntimeError", "exception.message" => "boom"}
    }

    test "matches by type, message and span" do
      spans = [span("job", events: [@exception])]

      assert %{name: "job"} = Trace.assert_exception(spans, "RuntimeError")
      assert %{name: "job"} = Trace.assert_exception(spans, ~r/boom/)
      assert %{name: "job"} = Trace.assert_exception(spans, type: "RuntimeError", span: "job")
    end

    test "fails without an exception event" do
      assert_raise ExUnit.AssertionError, ~r/no span has an exception/, fn ->
        Trace.assert_exception([span("job", [])], "RuntimeError")
      end
    end

    test "fails for a different type" do
      assert_raise ExUnit.AssertionError, fn ->
        Trace.assert_exception([span("job", events: [@exception])], "ArgumentError")
      end
    end

    test "fails when the exception is on another span" do
      assert_raise ExUnit.AssertionError, fn ->
        Trace.assert_exception([span("other", events: [@exception])], span: "job")
      end
    end
  end

  describe "assert_tree_intact and refute_span" do
    test "assert_tree_intact fails for an orphan" do
      assert_raise ExUnit.AssertionError, ~r/parent is missing/, fn ->
        Trace.assert_tree_intact([span("a", parent_span_id: "gone")])
      end
    end

    test "assert_tree_intact fails with no spans at all" do
      assert_raise ExUnit.AssertionError, ~r/no spans/, fn -> Trace.assert_tree_intact([]) end
    end

    test "refute_span fails when a span matches" do
      assert_raise ExUnit.AssertionError, ~r/expected no span/, fn ->
        Trace.refute_span([span("a", [])], "a")
      end
    end
  end

  describe "selection by key, against the real sink" do
    test "a span from another test's key is not visible" do
      key_a = TestKey.from_owner(self()) <> "-a"
      key_b = TestKey.from_owner(self()) <> "-b"

      TestKey.put(key_a)

      OpenTelemetry.Tracer.with_span "only-for-a" do
        :ok
      end

      TestKey.put(key_b)

      OpenTelemetry.Tracer.with_span "only-for-b" do
        :ok
      end

      assert {:ok, a_spans} = Backend.spans_for(key_a, 2_000)
      assert Enum.map(a_spans, & &1.name) == ["only-for-a"]

      assert {:ok, b_spans} = Backend.spans_for(key_b, 2_000)
      assert Enum.map(b_spans, & &1.name) == ["only-for-b"]

      assert_raise ExUnit.AssertionError, ~r/no span matches/, fn ->
        Trace.assert_span(key_b, "only-for-a", timeout: 50)
      end

      assert :ok = Trace.refute_span(key_b, "only-for-a")
    end

    test "a span with a different key is dropped from a shared trace" do
      key = TestKey.from_owner(self()) <> "-shared"
      other = key <> "-other"
      TestKey.put(key)

      OpenTelemetry.Tracer.with_span "parent" do
        TestKey.put(other)

        OpenTelemetry.Tracer.with_span "foreign" do
          :ok
        end

        TestKey.put(key)
      end

      {:ok, spans} = Backend.spans_for(key, 2_000)
      names = Enum.map(spans, & &1.name)
      assert "parent" in names
      refute "foreign" in names
    end

    test "an unknown key is an empty result, and asserting on it fails" do
      assert {:ok, []} = Backend.spans_for("unknown-#{System.unique_integer()}", 0)

      assert_raise ExUnit.AssertionError, ~r/no span matches/, fn ->
        Trace.assert_span("unknown-#{System.unique_integer()}", "x", timeout: 30)
      end
    end
  end
end
