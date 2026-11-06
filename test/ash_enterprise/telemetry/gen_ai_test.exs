defmodule AshEnterprise.Telemetry.GenAITest do
  @moduledoc """
  The GenAI spans an agent run is traced with (`AshEnterprise.Telemetry.GenAI`), read back
  from the test trace ring: their names and attributes against the pinned semantic
  conventions (v1.41.0), how they nest, how they end, and that no content reaches them.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.Execution.Runs
  import ExUnit.CaptureLog

  require OpenTelemetry.Tracer, as: Tracer

  alias AshAgent.OpenTelemetry, as: Mapping
  alias AshEnterprise.AI.Models.GuardedReqLLM
  alias AshEnterprise.Telemetry.TraceSink

  @target "AshEnterprise.Test.Execution.ClinicNote.record"
  @title "SYNTHETIC: call the lab about the morning panel"

  # What the v1.41.0 conventions mark Opt-In on these spans: content, never exported.
  @content [
    "gen_ai.input.messages",
    "gen_ai.output.messages",
    "gen_ai.system_instructions",
    "gen_ai.tool.definitions",
    "gen_ai.tool.call.arguments",
    "gen_ai.tool.call.result"
  ]

  setup do
    in_zone!()
    clinic = clinic!()
    %{clinic: clinic, version: published!(clinic)}
  end

  # A request's span, as the endpoint's would be: the trace everything joins.
  defp in_request(fun) do
    Tracer.with_span "test request" do
      {fun.(), trace_id(OpenTelemetry.Tracer.current_span_ctx())}
    end
  end

  defp trace_id(span_ctx), do: OpenTelemetry.Span.trace_id(span_ctx)

  # Attribute keys as strings: req_llm's bridge sets them as atoms.
  defp spans(trace_id, prefix) do
    trace = TraceSink.trace(trace_id)
    assert trace, "the request's trace is in the ring"

    for span <- trace.spans, String.starts_with?(span.name, prefix) do
      %{
        span
        | attributes: Map.new(span.attributes, fn {key, value} -> {to_string(key), value} end)
      }
    end
  end

  # The GenAI attributes: Ash's tracer also sets its own (`ash.*`) on the current span.
  defp gen_ai(span),
    do: Map.filter(span.attributes, fn {key, _} -> key =~ ~r/^(gen_ai|error)\./ end)

  defp under?(trace, span, ancestor) do
    by_id = Map.new(trace.spans, &{&1.span_id, &1})

    span.parent_span_id
    |> Stream.unfold(fn
      nil -> nil
      id -> {id, by_id[id] && by_id[id].parent_span_id}
    end)
    |> Enum.member?(ancestor.span_id)
  end

  defp content_free!(spans, plaintext) do
    assert for(span <- spans, key <- Map.keys(span.attributes), key in @content, do: key) == []

    leaks =
      for span <- spans,
          {key, value} <- span.attributes,
          is_binary(value),
          text <- plaintext,
          String.contains?(value, text),
          do: {span.name, key}

    assert leaks == []
  end

  describe "a run" do
    test "each step is an invoke_agent span in the trace that started it, and its tool call an execute_tool under the step",
         %{clinic: %{nurse: nurse}, version: version} do
      script!([{:tools, [record_call("call_lab", @title)]}, {:text, ~s({"recorded": 1})}])

      {{:ok, run}, trace_id} = in_request(fn -> start(nurse) end)
      assert is_binary(run.traceparent)

      assert %{success: 1} = Oban.drain_queue(queue: :agent_runs)
      assert %{failure: 0} = Oban.drain_queue(queue: :execution)
      assert %{success: 1} = Oban.drain_queue(queue: :agent_runs)

      [first, second] = spans(trace_id, "invoke_agent") |> Enum.sort_by(& &1.start_time)
      [tool] = spans(trace_id, "execute_tool")

      for step <- [first, second] do
        assert step.name == "invoke_agent clinic.note_taker"
        assert step.kind == :internal
        assert step.status_code == :ok

        assert gen_ai(step) == %{
                 "gen_ai.operation.name" => "invoke_agent",
                 "gen_ai.provider.name" => "openai",
                 "gen_ai.agent.name" => "clinic.note_taker",
                 "gen_ai.agent.version" => version.content_hash,
                 "gen_ai.conversation.id" => run.id
               }

        assert step.attributes["ash.correlation_id"] == run.correlation_id
      end

      assert tool.name == "execute_tool " <> @target
      assert tool.kind == :internal
      assert tool.status_code == :ok
      # Requested inside the first step, executed in a job of its own, traced under it.
      assert under?(TraceSink.trace(trace_id), tool, first)

      [call] = invocations(run)

      assert gen_ai(tool) == %{
               "gen_ai.operation.name" => "execute_tool",
               "gen_ai.tool.name" => @target,
               "gen_ai.tool.type" => "function",
               "gen_ai.tool.call.id" => "call_lab",
               "gen_ai.conversation.id" => run.id
             }

      assert tool.attributes["ash.correlation_id"] == call.correlation_id

      # The work inside a step is its child: its writes are traced under it.
      trace = TraceSink.trace(trace_id)
      assert Enum.any?(trace.spans, &(&1.parent_span_id == second.span_id))

      content_free!([first, second, tool], ["call the lab", version.instructions])
    end

    test "a step whose model call fails is not ok: it ends as an error naming the outcome",
         %{clinic: %{nurse: nurse}} do
      script!([{:error, :provider_down}])

      {{:ok, _run}, trace_id} = in_request(fn -> start(nurse) end)
      assert %{success: 1} = Oban.drain_queue(queue: :agent_runs)

      assert [step] = spans(trace_id, "invoke_agent")
      assert step.status_code == :error
      assert step.status_message == "interrupted"
      assert step.attributes["error.type"] == "interrupted"
    end

    test "a step whose worker dies is not ok: it ends as an error", %{clinic: %{nurse: nurse}} do
      script!([{:exit, :worker_killed}])

      {{:ok, _run}, trace_id} = in_request(fn -> start(nurse) end)
      Oban.drain_queue(queue: :agent_runs)

      assert [step] = spans(trace_id, "invoke_agent")
      assert step.status_code == :error
      assert step.attributes["error.type"] == "_OTHER"
    end
  end

  describe "an execution the handler is given" do
    # The events as ash_agent emits them, for results no real run produces on demand.
    defp execute(invocation, result_metadata) do
      in_request(fn ->
        :telemetry.span([:ash_agent, :invocation, :execute], %{invocation: invocation}, fn ->
          {:done, Map.merge(%{invocation: invocation}, result_metadata)}
        end)
      end)
    end

    defp row(traceparent),
      do: %{
        target: @target,
        tool_call_id: nil,
        run_id: nil,
        correlation_id: nil,
        traceparent: traceparent
      }

    test "only an outcome that finished the work is ok; a failure, an unknown outcome, an error or no result is not" do
      cases = [
        {%{result: {:ok, :succeeded}}, :ok, nil},
        {%{result: {:ok, :dispatched}}, :ok, nil},
        {%{result: {:ok, :failed}}, :error, "failed"},
        {%{result: {:ok, :outcome_unknown}}, :error, "outcome_unknown"},
        {%{result: {:ok, :stale}}, :error, "stale"},
        {%{result: {:ok, :superseded}}, :error, "superseded"},
        {%{result: {:ok, :something_new}}, :error, "something_new"},
        {%{result: {:error, :database_unavailable}}, :error, "_OTHER"},
        {%{result: nil}, :error, "_OTHER"},
        {%{}, :error, "_OTHER"}
      ]

      for {result, status, type} <- cases do
        {:done, trace_id} = execute(row(nil), result)
        assert [span] = spans(trace_id, "execute_tool"), inspect(result)
        assert span.status_code == status, inspect(result)
        assert span.attributes["error.type"] == type, inspect(result)
      end
    end

    test "a row recorded in another trace joins it; a traceparent that does not parse starts its own" do
      {_ok, request} = in_request(fn -> :ok end)

      other =
        Tracer.with_span "earlier request" do
          AshEnterprise.Execution.AgentRuntime.traceparent()
        end

      {:done, here} = execute(row(other), %{result: {:ok, :succeeded}})
      assert spans(here, "execute_tool") == []
      other_trace = other |> String.split("-") |> Enum.at(1)
      assert [_span] = spans(other_trace, "execute_tool")

      {:done, here} = execute(row("00-not-a-trace"), %{result: {:ok, :succeeded}})
      assert spans(here, "execute_tool") == []
      refute request == here
    end

    test "a stop with no start, or metadata it cannot read, is dropped and the handler stays attached" do
      :telemetry.execute([:ash_agent, :invocation, :execute, :stop], %{}, %{
        telemetry_span_context: make_ref(),
        result: {:ok, :succeeded}
      })

      assert capture_log(fn ->
               :telemetry.execute([:ash_agent, :run, :step, :start], %{}, %{run: %{}})
             end) =~ "no span for"

      handlers = :telemetry.list_handlers([:ash_agent, :invocation, :execute, :start])
      assert Enum.any?(handlers, &(&1.id == "ash_enterprise-gen-ai"))
    end
  end

  describe "a model call" do
    setup do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "id" => "chatcmpl-test",
          "object" => "chat.completion",
          "model" => "in-zone-model",
          "choices" => [
            %{
              "index" => 0,
              "finish_reason" => "stop",
              "message" => %{"role" => "assistant", "content" => "SYNTHETIC answer text"}
            }
          ],
          "usage" => %{"prompt_tokens" => 21, "completion_tokens" => 4, "total_tokens" => 25}
        })
      end)

      :ok
    end

    test "is req_llm's chat span, under the span that made it, with no content even when raw payloads are asked for" do
      {result, trace_id} =
        in_request(fn ->
          GuardedReqLLM.generate_text(
            AshEnterprise.AI.Models.default_spec(),
            "SYNTHETIC prompt text",
            caller: "test.gen_ai",
            telemetry: [payloads: :raw],
            req_http_options: [plug: {Req.Test, __MODULE__}]
          )
        end)

      assert {:ok, _response} = result

      assert [chat] = spans(trace_id, "chat")
      assert chat.kind == :client
      assert chat.attributes["gen_ai.operation.name"] == "chat"
      assert chat.attributes["gen_ai.provider.name"] == "openai"
      assert is_binary(chat.attributes["gen_ai.request.model"])
      assert chat.attributes["gen_ai.usage.input_tokens"] == 21
      assert chat.attributes["gen_ai.usage.output_tokens"] == 4
      assert TraceSink.trace(trace_id).root.span_id == chat.parent_span_id

      content_free!([chat], ["SYNTHETIC prompt text", "SYNTHETIC answer text"])
    end
  end

  test "names follow the version the mapping pins" do
    assert Mapping.version() == "1.41.0"
  end
end
