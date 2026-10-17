defmodule AshEnterprise.Assistant.RunnerTest do
  @moduledoc """
  The assistant's tool-use loop (E10.1/E10.2) against a scripted stand-in for
  the in-zone model: multi-step tool calls, the step cap, failures, stopping,
  what is recorded, and the refusal of anything outside the zone. Synthetic
  data and synthetic model output only; nothing reaches a network.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.AI.ModelCall
  alias AshEnterprise.Assistant.{History, Runner, Thread, Turn}
  alias AshEnterprise.Test.AssistantFixtures, as: F
  alias AshEnterprise.Test.AssistantFixtures.ScriptedModel
  alias AshEnterprise.Test.DailyFixtures, as: D

  setup do
    F.in_zone!()
    ctx = F.tenant!()
    {:ok, thread} = Thread.start("SYNTHETIC thread", actor: ctx.actor, tenant: ctx.tenant)
    Map.put(ctx, :thread, thread)
  end

  defp run(ctx, opts) do
    Runner.run([thread: ctx.thread, actor: ctx.actor, tenant: ctx.tenant] ++ opts)
  end

  defp events do
    receive do
      {:assistant, _ref, event} -> [event | events()]
    after
      0 -> []
    end
  end

  defp calls, do: Ash.read!(ModelCall, authorize?: false)

  defp text(%{content: parts}) when is_list(parts), do: Enum.map_join(parts, &(&1.text || ""))
  defp text(%{content: text}) when is_binary(text), do: text

  describe "the loop" do
    test "calls tools across several steps, then answers with citations", ctx do
      event = D.event!(ctx, "SYNTHETIC planning review", 60 * 24, 30)
      D.person!(ctx, "zed@example.test", "Zed Example")

      ScriptedModel.script!([
        {:tools, [{"calendar_events", %{"input" => %{"window" => "this_week"}}}]},
        {:tools, [{"find_people", %{"input" => %{"query" => "zed"}}}]},
        {:text, "You have the SYNTHETIC planning review [[calendar:#{event.id}]]."}
      ])

      assert {:ok, %Turn{} = answer} = run(ctx, question: "SYNTHETIC: what is on this week?")

      assert answer.role == :assistant
      assert answer.status == :complete
      assert answer.content =~ "[[calendar:#{event.id}]]"
      assert answer.iterations == 3
      assert "calendar:#{event.id}" in answer.refs

      assert [
               %{"name" => "calendar_events", "ok" => true, "count" => 1},
               %{"name" => "find_people", "ok" => true, "count" => 1}
             ] = answer.tool_calls["calls"]

      # The question and the answer are both recorded, in order.
      assert [%{turn: %{role: :user}}, %{turn: %{role: :assistant}}] =
               History.load(ctx.thread.id, actor: ctx.actor, tenant: ctx.tenant)
               |> elem(1)
               |> Map.fetch!(:turns)

      # Each tool result went back to the model before the next step.
      assert_received {:model_request, first, tools, _opts}
      assert "calendar_events" in tools and "count_activity" in tools
      assert "compose_surface" in tools and "propose_task" in tools and length(tools) == 12
      assert Enum.any?(first, &(&1.role == :system))
      assert_received {:model_request, second, _tools, _opts}
      assert Enum.any?(second, &(&1.role == :tool))

      kinds = events() |> Enum.map(&if is_tuple(&1), do: elem(&1, 0), else: &1)
      assert :user_turn in kinds and :tool_call in kinds and :tool_result in kinds
      assert :text in kinds and :done in kinds

      # Three model calls, each through the guard, each recorded in-zone.
      assert [_, _, _] = records = Enum.filter(calls(), &(&1.caller == "assistant.chat"))
      assert Enum.all?(records, &(&1.residency == :in_zone and &1.outcome == :ok))
      assert Enum.all?(records, &(&1.zone == F.zone()))
    end

    test "a tool error is handed back to the model, which recovers", ctx do
      ScriptedModel.script!([
        {:tools, [{"calendar_events", %{"input" => %{"window" => "SYNTHETIC-NOT-A-WINDOW"}}}]},
        {:tools, [{"no_such_tool", %{}}]},
        {:text, "SYNTHETIC: I could not read that window."}
      ])

      assert {:ok, answer} = run(ctx, question: "SYNTHETIC: what happened then?")
      assert answer.status == :complete

      assert [
               %{"name" => "calendar_events", "ok" => false},
               %{"name" => "no_such_tool", "ok" => false}
             ] =
               answer.tool_calls["calls"]

      assert_received {:model_request, _first, _, _}
      assert_received {:model_request, second, _, _}

      assert Enum.any?(second, fn message ->
               message.role == :tool and text(message) =~ "is not a window"
             end)
    end

    test "the step cap stops the lookups and asks for an answer without tools", ctx do
      looping = {:tools, [{"pending_approvals", %{"input" => %{}}}]}
      ScriptedModel.script!([looping, looping, {:text, "SYNTHETIC: nothing is waiting."}])

      assert {:ok, answer} = run(ctx, question: "SYNTHETIC: approvals?", max_steps: 2)
      assert answer.status == :complete
      assert answer.content == "SYNTHETIC: nothing is waiting."
      assert length(answer.tool_calls["calls"]) == 2

      assert_received {:model_request, _, [_ | _], _}
      assert_received {:model_request, _, [_ | _], _}
      # The final call carries no tools.
      assert_received {:model_request, final, [], _}
      assert List.last(final).role == :user
    end

    test "a cap with no answer after it fails as step_cap", ctx do
      looping = {:tools, [{"pending_approvals", %{"input" => %{}}}]}
      ScriptedModel.script!([looping, looping, {:text, ""}])

      assert {:error, :step_cap, %Turn{status: :failed, error_class: "step_cap"}} =
               run(ctx, question: "SYNTHETIC: approvals?", max_steps: 2)
    end

    test "an unreachable model fails the answer and keeps the question for a retry", ctx do
      ScriptedModel.script!([{:error, %ReqLLM.Error.API.Request{reason: "SYNTHETIC timeout"}}])

      assert {:error, :model_unreachable, %Turn{status: :failed} = failed} =
               run(ctx, question: "SYNTHETIC: are you there?")

      assert failed.error_class == "model_unreachable"
      assert [%{outcome: :error}] = Enum.filter(calls(), &(&1.caller == "assistant.chat"))

      # Retry answers the same question again, as a new answer.
      {:ok, %{turns: [question, _failed]}} =
        History.load(ctx.thread.id, actor: ctx.actor, tenant: ctx.tenant)

      ScriptedModel.script!([{:text, "SYNTHETIC: back now."}])
      assert {:ok, %Turn{status: :complete}} = run(ctx, retry: question.turn)

      {:ok, %{turns: turns}} = History.load(ctx.thread.id, actor: ctx.actor, tenant: ctx.tenant)

      assert Enum.map(turns, &{&1.turn.role, &1.turn.status}) ==
               [{:user, :complete}, {:assistant, :failed}, {:assistant, :complete}]
    end

    test "a stream that breaks while it is read fails as unreachable", ctx do
      ScriptedModel.script!([{:raise, %Req.TransportError{reason: :closed}}])

      assert {:error, :model_unreachable, %Turn{status: :failed}} =
               run(ctx, question: "SYNTHETIC: still there?")
    end

    test "the engine recovering (503) is told apart from unreachable" do
      assert Runner.classify(%ReqLLM.Error.API.Request{status: 503}) == :model_recovering
      assert Runner.classify(%ReqLLM.Error.API.Request{status: nil}) == :model_unreachable
      assert Runner.classify(:max_iterations_reached) == :step_cap
      assert Runner.classify(%RuntimeError{message: "SYNTHETIC"}) == :model_error
    end

    test "stop ends the run at the next chunk and records what it had", ctx do
      ScriptedModel.script!([{:pause, "SYNTHETIC-PARTIAL"}])
      ref = make_ref()

      {:ok, pid} =
        Runner.start(
          thread: ctx.thread,
          actor: ctx.actor,
          tenant: ctx.tenant,
          question: "SYNTHETIC: tell me a long story",
          notify: self(),
          ref: ref
        )

      assert_receive {:assistant, ^ref, {:text, "SYNTHETIC-PARTIAL"}}, 5_000
      send(pid, {:assistant_stop, ref})
      send(pid, :scripted_continue)

      assert_receive {:assistant, ^ref, {:done, %Turn{status: :stopped} = turn}}, 5_000
      assert turn.content == "SYNTHETIC-PARTIAL"
    end

    test "the next question carries the conversation so far, as text only", ctx do
      ScriptedModel.script!([{:text, "SYNTHETIC-FIRST-ANSWER"}])
      assert {:ok, _} = run(ctx, question: "SYNTHETIC-FIRST-QUESTION")
      assert_received {:model_request, _, _, _}

      ScriptedModel.script!([{:text, "SYNTHETIC-SECOND-ANSWER"}])
      assert {:ok, _} = run(ctx, question: "SYNTHETIC-SECOND-QUESTION")
      assert_received {:model_request, messages, _, _}

      texts = Enum.map(messages, &{&1.role, text(&1)})
      assert [{:system, _}, {:user, q1}, {:assistant, a1}, {:user, q2}] = texts
      assert q1 =~ "SYNTHETIC-FIRST-QUESTION" and a1 =~ "SYNTHETIC-FIRST-ANSWER"
      assert q2 =~ "SYNTHETIC-SECOND-QUESTION"
    end
  end

  describe "the zone" do
    test "with no in-zone profile nothing is asked: no hosted fallback", ctx do
      Application.put_env(:ash_enterprise, :ai, [])
      ScriptedModel.script!([{:text, "SYNTHETIC: must never be produced"}])

      assert {:error, :not_configured, %Turn{status: :failed}} =
               run(ctx, question: "SYNTHETIC: hello?")

      refute_received {:model_request, _, _, _}
      assert [%{outcome: :refused, residency: :outside_zone}] = calls()
    end

    test "a hosted model spec is refused for the assistant, guard on or off", ctx do
      for guard <- [false, true] do
        F.in_zone!(ai: [require_in_zone_models: guard])
        ScriptedModel.script!([{:text, "SYNTHETIC: must never be produced"}])

        assert {:error, :outside_zone, _} =
                 run(ctx,
                   question: "SYNTHETIC: hello?",
                   model: "anthropic:claude-haiku-4-5-20251001"
                 )

        refute_received {:model_request, _, _, _}
      end

      assert Enum.all?(calls(), &(&1.outcome == :refused and &1.residency == :outside_zone))
    end

    test "an in-zone profile outside the canonical store's zone is refused", ctx do
      F.in_zone!(profile_zone: "SYNTHETIC-OTHER-ZONE")
      ScriptedModel.script!([{:text, "SYNTHETIC: must never be produced"}])

      assert {:error, :zone_mismatch, _} = run(ctx, question: "SYNTHETIC: hello?")
      refute_received {:model_request, _, _, _}
    end

    test "under REQUIRE_IN_ZONE_MODELS the guard itself refuses a hosted target for these tools",
         ctx do
      F.in_zone!(ai: [require_in_zone_models: true])

      assert_raise AshEnterprise.AI.Models.OutsideZone, fn ->
        AshAi.ToolLoop.run([ReqLLM.Context.user("SYNTHETIC")],
          model: "anthropic:claude-haiku-4-5-20251001",
          req_llm: AshEnterprise.AI.Models.GuardedReqLLM,
          req_llm_opts: [caller: "assistant.chat", downstream: ScriptedModel],
          actions: [{AshEnterprise.Assistant.Lookup, :*}],
          actor: ctx.actor,
          tenant: ctx.tenant
        )
      end

      assert [%{outcome: :refused, residency: :outside_zone}] = calls()
    end
  end

  describe "composing and proposing" do
    test "a composed surface is handed to the page and recorded on the call", ctx do
      ScriptedModel.script!([
        {:tools, [{"compose_surface", %{"input" => %{"show" => "tasks", "display" => "board"}}}]},
        {:text, "SYNTHETIC: your tasks are on a board."}
      ])

      assert {:ok, answer} = run(ctx, question: "SYNTHETIC: board my tasks")

      assert [%{"name" => "compose_surface", "ok" => true, "surface" => surface}] =
               answer.tool_calls["calls"]

      assert %{"id" => "s" <> _, "request" => %{"show" => "tasks", "display" => "board"}} =
               surface

      assert {:surface, %{id: id, request: %{"show" => "tasks"}}} =
               Enum.find(events(), &match?({:surface, _}, &1))

      assert id == surface["id"]
    end

    test "a refused spec goes back to the model as a short reason", ctx do
      ScriptedModel.script!([
        {:tools,
         [{"compose_surface", %{"input" => %{"show" => "people", "display" => "calendar"}}}]},
        {:text, "SYNTHETIC: people cannot go on a calendar."}
      ])

      assert {:ok, answer} = run(ctx, question: "SYNTHETIC: people on a calendar")
      assert [%{"name" => "compose_surface", "ok" => false} = call] = answer.tool_calls["calls"]
      refute Map.has_key?(call, "surface")

      assert_received {:model_request, _first, _, _}
      assert_received {:model_request, second, _, _}

      assert Enum.any?(second, fn message ->
               message.role == :tool and text(message) =~ "use a table"
             end)
    end

    test "a proposal is handed to the page and changes nothing", ctx do
      ScriptedModel.script!([
        {:tools,
         [
           {"propose_task",
            %{"input" => %{"change" => "add", "title" => "SYNTHETIC file the report"}}}
         ]},
        {:text, "SYNTHETIC: I proposed adding it; confirm to add it."}
      ])

      assert {:ok, answer} = run(ctx, question: "SYNTHETIC: remind me to file the report")

      assert [%{"name" => "propose_task", "proposal" => %{"wire" => wire, "id" => "p" <> _}}] =
               answer.tool_calls["calls"]

      assert wire["kind"] == "create_task"
      assert {:proposal, %{wire: ^wire}} = Enum.find(events(), &match?({:proposal, _}, &1))
      assert AshEnterprise.Canonical.Task.mine!(actor: ctx.actor, tenant: ctx.tenant) == []
    end
  end
end
