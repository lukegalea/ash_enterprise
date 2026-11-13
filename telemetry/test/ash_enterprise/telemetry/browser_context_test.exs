defmodule AshEnterprise.Telemetry.BrowserContextTest do
  use ExUnit.Case, async: false

  alias AshEnterprise.Telemetry.BrowserContext
  alias AshEnterprise.Telemetry.Correlation
  alias AshEnterprise.Telemetry.RaisingCorrelation
  alias AshEnterprise.Telemetry.Settings
  alias OpenTelemetry.Tracer

  import AshEnterprise.Telemetry.TraceHelpers
  import Phoenix.ConnTest, only: [build_conn: 0, get: 2]
  import Phoenix.LiveViewTest

  require OpenTelemetry.Tracer

  @endpoint AshEnterprise.Telemetry.TestEndpoint

  defp event_meta(event, params, extra \\ %{}) do
    Map.merge(
      %{
        socket: %{view: __MODULE__, transport_pid: self(), private: %{}},
        event: event,
        params: params
      },
      extra
    )
  end

  @handle_event [:phoenix, :live_view, :handle_event]

  defp run_event(meta) when is_map(meta), do: run_event(@handle_event, meta, fn -> :ok end)

  defp run_event(meta, fun) when is_map(meta) and is_function(fun),
    do: run_event(@handle_event, meta, fun)

  defp run_event(prefix, meta) when is_list(prefix), do: run_event(prefix, meta, fn -> :ok end)

  defp run_event(prefix, meta, fun) do
    :telemetry.span(prefix, meta, fn -> {fun.(), meta} end)
  end

  defp unique_event(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp handle_event_span(key, event), do: span_named_ending(key, "handle_event##{event}")

  defp assert_no_active_context do
    assert Tracer.current_span_ctx() == :undefined
  end

  describe "traceparent validation" do
    test "accepts a well-formed version 00 value" do
      assert BrowserContext.valid_traceparent?(
               "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
             )
    end

    test "rejects anything else" do
      for bad <- [
            nil,
            123,
            "",
            "garbage",
            "ff-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
            "00-0AF7651916CD43DD8448EB211C80319C-b7ad6b7169203331-01",
            "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331",
            "00-00000000000000000000000000000000-b7ad6b7169203331-01",
            "00-0af7651916cd43dd8448eb211c80319c-0000000000000000-01",
            "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01-extra",
            "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" <>
              String.duplicate("a", 500)
          ] do
        refute BrowserContext.valid_traceparent?(bad), "accepted #{inspect(bad)}"
      end
    end
  end

  describe "adopting browser context" do
    test "the event span becomes a child of the browser span" do
      key = test_key!()
      tp = traceparent()
      event = unique_event("adopt")

      run_event(event_meta(event, %{"_traceparent" => tp.header}))

      span = handle_event_span(key, event)
      assert span.trace_id == tp.trace_id
      assert span.parent_span_id == tp.span_id
      assert attr(span, "ash.parent_remote") == true
    end

    test "a malformed traceparent is rejected and the span is a new root" do
      key = test_key!()
      event = unique_event("malformed")

      run_event(event_meta(event, %{"_traceparent" => "00-notreally-abc-01"}))

      span = handle_event_span(key, event)
      assert span.parent_span_id == :undefined
    end

    test "a non-string traceparent is rejected" do
      key = test_key!()
      event = unique_event("nonstring")
      run_event(event_meta(event, %{"_traceparent" => %{"nested" => true}}))
      assert handle_event_span(key, event).parent_span_id == :undefined
    end

    test "a client's flags do not change whether the parent is adopted" do
      key = test_key!()

      for flags <- ["00", "01", "ff"] do
        tp = traceparent(flags)
        event = unique_event("flag")

        run_event(event_meta(event, %{"_traceparent" => tp.header}))

        span = handle_event_span(key, event)
        assert span, "no span recorded for client flags #{flags}"
        assert span.trace_id == tp.trace_id
      end
    end

    test "with browser context off, a traceparent is ignored" do
      Settings.put(%{browser_context?: false, event_attributes: nil})

      try do
        key = test_key!()
        tp = traceparent()
        event = unique_event("off")
        run_event(event_meta(event, %{"_traceparent" => tp.header}))
        assert handle_event_span(key, event).parent_span_id == :undefined
      after
        Settings.put(%{
          browser_context?: true,
          event_attributes: {AshEnterprise.Telemetry.TestEventAttributes, :resolve, []}
        })
      end
    end

    test "the connected mount is parented by the connect traceparent" do
      key = test_key!()
      tp = traceparent()

      meta = %{
        socket: %{
          view: __MODULE__,
          transport_pid: self(),
          private: %{connect_params: %{"_traceparent" => tp.header}}
        },
        params: %{}
      }

      run_event([:phoenix, :live_view, :mount], meta)

      span = span_named_ending(key, ".mount")
      assert span.parent_span_id == tp.span_id
    end

    test "a query-string traceparent does not parent a mount" do
      key = test_key!()
      tp = traceparent()

      meta = %{
        socket: %{view: __MODULE__, transport_pid: self(), private: %{}},
        params: %{"_traceparent" => tp.header}
      }

      run_event([:phoenix, :live_view, :mount], meta)

      assert span_named_ending(key, ".mount").parent_span_id == :undefined
    end
  end

  describe "no leakage across events in one process" do
    test "stop detaches: the next event is a new root" do
      key = test_key!()
      tp = traceparent()
      first = unique_event("first")
      second = unique_event("second")

      run_event(event_meta(first, %{"_traceparent" => tp.header}))
      assert_no_active_context()

      run_event(event_meta(second, %{}))

      assert handle_event_span(key, first).trace_id == tp.trace_id
      assert handle_event_span(key, second).parent_span_id == :undefined
      assert handle_event_span(key, second).trace_id != tp.trace_id
    end

    test "an exception detaches: the next event is a new root" do
      key = test_key!()
      tp = traceparent()
      first = unique_event("raises")
      second = unique_event("after-raise")

      assert_raise RuntimeError, fn ->
        run_event(event_meta(first, %{"_traceparent" => tp.header}), fn -> raise "boom" end)
      end

      assert_no_active_context()

      run_event(event_meta(second, %{}))
      assert handle_event_span(key, second).trace_id != tp.trace_id
    end

    test "the live_component exception path detaches too" do
      key = test_key!()
      tp = traceparent()
      first = unique_event("component-raises")
      second = unique_event("component-after")

      meta = event_meta(first, %{"_traceparent" => tp.header}, %{component: __MODULE__})

      assert_raise RuntimeError, fn ->
        run_event([:phoenix, :live_component, :handle_event], meta, fn -> raise "boom" end)
      end

      assert_no_active_context()

      run_event(
        [:phoenix, :live_component, :handle_event],
        event_meta(second, %{}, %{component: __MODULE__})
      )

      span = handle_event_span(key, second)
      assert span.parent_span_id == :undefined
      assert span.trace_id != tp.trace_id
    end

    test "the exception is recorded on the span" do
      key = test_key!()
      event = unique_event("exc")

      assert_raise RuntimeError, fn ->
        run_event(event_meta(event, %{}), fn -> raise "boom" end)
      end

      assert [%{name: "exception"}] = handle_event_span(key, event).events
    end
  end

  describe "correlation" do
    test "each event gets a fresh server-minted id, and the previous id is restored" do
      key = test_key!()
      Correlation.put("mount-id")
      first = unique_event("c1")
      second = unique_event("c2")

      run_event(event_meta(first, %{}))
      assert Correlation.current() == "mount-id"
      run_event(event_meta(second, %{}))

      first_id = attr(handle_event_span(key, first), "ash.correlation_id")
      second_id = attr(handle_event_span(key, second), "ash.correlation_id")

      assert first_id && second_id
      refute first_id == "mount-id"
      refute first_id == second_id
    end

    test "a correlation id from the browser is never accepted" do
      key = test_key!()
      event = unique_event("forged")

      run_event(
        event_meta(event, %{"correlation_id" => "forged", "ash.correlation_id" => "forged"})
      )

      refute attr(handle_event_span(key, event), "ash.correlation_id") == "forged"
    end

    test "the exception path restores the previous id" do
      test_key!()
      Correlation.put("before")

      assert_raise RuntimeError, fn ->
        run_event(event_meta(unique_event("exc-corr"), %{}), fn -> raise "boom" end)
      end

      assert Correlation.current() == "before"
    end

    test "with no id before an event, none remains after" do
      test_key!()
      assert Correlation.current() == nil
      run_event(event_meta(unique_event("clears"), %{}))
      assert Correlation.current() == nil
    end

    test "mount mints an id, kept through the handle_params that follows" do
      key = test_key!()
      meta = %{socket: %{view: __MODULE__, transport_pid: self(), private: %{}}, params: %{}}

      run_event([:phoenix, :live_view, :mount], meta)
      minted = Correlation.current()
      run_event([:phoenix, :live_view, :handle_params], meta)

      assert minted
      assert Correlation.current() == minted
      assert attr(span_named_ending(key, ".handle_params"), "ash.correlation_id") == minted
    end

    test "a later handle_params (a patch) gets its own id" do
      key = test_key!()
      Correlation.put("mount-id")
      meta = %{socket: %{view: __MODULE__, transport_pid: self(), private: %{}}, params: %{}}

      run_event([:phoenix, :live_view, :handle_params], meta)

      assert attr(span_named_ending(key, ".handle_params"), "ash.correlation_id") != "mount-id"
      assert Correlation.current() == "mount-id"
    end

    test "a dead render keeps the request's id" do
      test_key!()
      Correlation.put("request-id")
      meta = %{socket: %{view: __MODULE__, transport_pid: nil, private: %{}}, params: %{}}

      run_event([:phoenix, :live_view, :mount], meta)

      assert Correlation.current() == "request-id"
    end
  end

  describe "naming the user action" do
    test "the event name and view are always on the span" do
      key = test_key!()
      event = unique_event("plain")
      run_event(event_meta(event, %{}))

      span = handle_event_span(key, event)
      assert attr(span, "ui.event.name") == event
      assert attr(span, "ui.view") =~ "BrowserContextTest"
    end

    test "the hook's attributes land on the handle_event span" do
      key = test_key!()
      run_event(event_meta("named", %{}))

      span = handle_event_span(key, "named")
      assert attr(span, "ui.action.name") == "activate"
      assert attr(span, "ui.action.resource") == "Widget"
    end

    test "the A2UI resolver names the action and surface from the envelope" do
      key = test_key!()

      params = %{
        "version" => "1.0",
        "callAgentFunction" => %{
          "surfaceId" => "email_templates",
          "functionCallId" => "fc_1",
          "callFunction" => %{
            "@call" => "ashAction",
            "args" => %{
              "name" => "activate_template",
              "context" => %{"email" => "secret@example.com"}
            }
          }
        }
      }

      run_event(event_meta("a2ui:message", params))

      span = handle_event_span(key, "a2ui:message")
      assert attr(span, "ui.event.name") == "a2ui:message"
      assert attr(span, "ui.action.name") == "activate_template"
      assert attr(span, "ui.surface.id") == "email_templates"
      refute inspect(span.attributes) =~ "secret@example.com"
    end

    test "a resolver cannot forge a reserved attribute" do
      key = test_key!()
      run_event(event_meta("forge", %{}))

      span = handle_event_span(key, "forge")
      refute attr(span, "ash.correlation_id") == "forged"
      assert attr(span, "ui.action.name") == "x"
    end
  end

  describe "handler failures never reach the traced code" do
    test "a raising resolver does not crash the event or detach the handler" do
      key = test_key!()

      assert run_event(event_meta("boom", %{})) == :ok
      assert handle_event_span(key, "boom")

      assert Enum.any?(
               :telemetry.list_handlers([:phoenix, :live_view, :handle_event, :start]),
               &(&1.id == {BrowserContext, :after})
             )
    end

    test "a raising correlation module does not crash the event, detach the handler or leak context" do
      original = Settings.correlation()
      Settings.put(%{correlation: RaisingCorrelation, browser_context?: true})

      try do
        tp = traceparent()

        assert BrowserContext.handle_before(
                 [:phoenix, :live_view, :handle_event, :start],
                 %{},
                 Map.put(
                   event_meta(unique_event("corr-fail"), %{"_traceparent" => tp.header}),
                   :telemetry_span_context,
                   make_ref()
                 ),
                 nil
               ) == :ok

        assert_no_active_context()

        assert run_event(event_meta(unique_event("corr-fail"), %{"_traceparent" => tp.header})) ==
                 :ok

        assert_no_active_context()

        assert Enum.any?(
                 :telemetry.list_handlers([:phoenix, :live_view, :handle_event, :start]),
                 &(&1.id == {BrowserContext, :before})
               )
      after
        Settings.put(%{
          correlation: original,
          browser_context?: true,
          event_attributes: {AshEnterprise.Telemetry.TestEventAttributes, :resolve, []}
        })
      end
    end

    test "garbage metadata is tolerated" do
      for meta <- [
            %{},
            %{params: nil},
            %{socket: :nope, event: 1, telemetry_span_context: make_ref()}
          ] do
        assert BrowserContext.handle_before(
                 [:phoenix, :live_view, :handle_event, :start],
                 %{},
                 meta,
                 nil
               ) == :ok

        assert BrowserContext.handle_after(
                 [:phoenix, :live_view, :handle_event, :stop],
                 %{},
                 meta,
                 nil
               ) == :ok
      end
    end
  end

  test "an oversized multi-byte attribute is cut on a character boundary" do
    key = test_key!()
    value = String.duplicate("日本語", 200)

    Settings.put(%{
      browser_context?: true,
      event_attributes: fn _event, _params, _socket -> %{"ui.action.name" => value} end
    })

    try do
      event = unique_event("utf8b")
      run_event(event_meta(event, %{}))
      span = handle_event_span(key, event)
      name = attr(span, "ui.action.name")
      assert String.valid?(name)
      assert byte_size(name) <= 256
    after
      Settings.put(%{
        browser_context?: true,
        event_attributes: {AshEnterprise.Telemetry.TestEventAttributes, :resolve, []}
      })
    end
  end

  describe "a real LiveView" do
    setup do
      {:ok, conn: build_conn()}
    end

    test "a browser-parented event and its child span share one trace", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/live")
      tp = traceparent()

      render_click(view, "trace", %{"_traceparent" => tp.header})

      trace = eventually(fn -> AshEnterprise.Telemetry.TraceSink.trace(tp.trace_id) end)
      names = Enum.map(trace.spans, & &1.name)

      assert "inside.event" in names
      assert Enum.any?(names, &String.ends_with?(&1, "handle_event#trace"))
      assert Enum.all?(trace.spans, &is_binary(attr(&1, "ash.correlation_id")))
    end

    test "after a raising event, the next mount starts clean", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/live")
      tp = traceparent()

      Process.flag(:trap_exit, true)
      catch_exit(render_click(view, "raise", %{"_traceparent" => tp.header}))

      trace = eventually(fn -> AshEnterprise.Telemetry.TraceSink.trace(tp.trace_id) end)
      assert Enum.any?(trace.spans, &match?([%{name: "exception"} | _], &1.events))

      {:ok, next_view, _html} = live(conn, "/live")
      event = unique_event("after-crash")
      render_click(next_view, event, %{})

      span =
        eventually(fn ->
          Enum.find(AshEnterprise.Telemetry.TraceSink.last(500), fn candidate ->
            Enum.any?(candidate.spans, &String.ends_with?(&1.name, "handle_event##{event}"))
          end)
        end)

      refute span.trace_id == tp.trace_id
      refute Enum.any?(span.spans, &(&1.parent_span_id == tp.span_id))
    end

    test "a handle_event crash exports neither form values nor assigns", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/live")
      tp = traceparent()

      Process.flag(:trap_exit, true)

      catch_exit(
        render_click(view, "clause", %{
          "_traceparent" => tp.header,
          "password" => "form-secret-value"
        })
      )

      trace = eventually(fn -> AshEnterprise.Telemetry.TraceSink.trace(tp.trace_id) end)
      [%{attributes: attributes}] = Enum.flat_map(trace.spans, & &1.events)

      refute attributes[:"exception.stacktrace"] =~ "form-secret-value"
      refute attributes[:"exception.stacktrace"] =~ "assign-secret-value"
      assert attributes[:"exception.stacktrace"] =~ "only_never/2"
    end

    test "a MatchError over a form value does not print the value", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/live")
      tp = traceparent()

      Process.flag(:trap_exit, true)

      catch_exit(
        render_click(view, "match", %{
          "_traceparent" => tp.header,
          "password" => "match-secret-value"
        })
      )

      trace = eventually(fn -> AshEnterprise.Telemetry.TraceSink.trace(tp.trace_id) end)
      [%{attributes: attributes}] = Enum.flat_map(trace.spans, & &1.events)

      refute attributes[:"exception.message"] =~ "match-secret-value"
    end
  end

  describe "sampling a forged parent" do
    defp sampled_decision(spec, tp) do
      ctx =
        :otel_propagator_text_map.extract_to(OpenTelemetry.Ctx.new(), [{"traceparent", tp.header}])

      sampler = :otel_sampler.new(spec)

      {decision, _attributes, _tracestate} =
        :otel_sampler.should_sample(sampler, ctx, tp.trace_id, [], "span", :server, %{})

      decision
    end

    test "the SDK's default sampler would obey the forced flag, which is why sampler/1 exists" do
      assert sampled_decision({:parent_based, %{root: :always_off}}, traceparent("01")) ==
               :record_and_sample
    end

    test "the shipped sampler sends a forced parent to the root sampler" do
      spec = AshEnterprise.Telemetry.sampler(:always_off)
      assert sampled_decision(spec, traceparent("01")) == :drop
    end

    test "the shipped sampler records a forced parent when the root sampler says to" do
      spec = AshEnterprise.Telemetry.sampler(:always_on)
      assert sampled_decision(spec, traceparent("01")) == :record_and_sample
    end

    test "a local child still follows its local parent" do
      assert {:parent_based, %{root: :always_off, remote_parent_sampled: :always_off} = config} =
               AshEnterprise.Telemetry.sampler(:always_off)

      refute Map.has_key?(config, :local_parent_sampled)
    end
  end

  test "current_traceparent names the active span and is nil outside one" do
    assert BrowserContext.current_traceparent() == nil

    Tracer.with_span "meta.span" do
      assert BrowserContext.valid_traceparent?(BrowserContext.current_traceparent())
    end
  end
end
