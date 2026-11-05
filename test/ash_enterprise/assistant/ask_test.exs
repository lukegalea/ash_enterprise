defmodule AshEnterprise.Assistant.AskTest do
  @moduledoc """
  The assistant on durable agent runs (AGT-33): each answer is a run of the assistant
  agent, its lookups are reads the run takes in its loop, and the answer is recorded
  from the run's journal however the run ends. Against a scripted stand-in for the
  in-zone model; synthetic data and synthetic model output only, nothing reaches a
  network.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.AI.ModelCall
  alias AshEnterprise.Assistant.{Ask, History, Requests, Thread, Turn}
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Execution
  alias AshEnterprise.Test.AssistantFixtures, as: F
  alias AshEnterprise.Test.AssistantFixtures.ScriptedModel
  alias AshEnterprise.Test.DailyFixtures, as: D
  alias AshEnterprise.Test.Execution.Runs

  setup do
    F.in_zone!()
    ctx = F.tenant!()
    F.published!(ctx)
    Map.put(ctx, :thread, F.thread!(ctx))
  end

  defp ask(ctx, question), do: F.ask!(ctx, ctx.thread, question)

  defp calls, do: Ash.read!(ModelCall, authorize?: false)

  defp settle(ctx, run), do: Ask.settle(ctx.thread, run.id, F.opts(ctx))

  # The model asks to add an action item, saying so, then answers once it hears back.
  defp ask_to_add!(_ctx) do
    ScriptedModel.script!([
      {:tools, [{"add_action_item", %{"input" => %{"title" => "SYNTHETIC file the report"}}}],
       "SYNTHETIC: I asked to add it; confirm it to add it."},
      {:text, "SYNTHETIC: added."}
    ])
  end

  # The step the decision's wake-up enqueued (the queues are manual here), then the rest.
  defp wake!(run) do
    _ = Runs.step!(Runs.run(run))
    F.run_out!(run)
  end

  # The run's deadline passed a minute ago. Written past the actions, as the clock is.
  defp deadline_passes!(run) do
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    {1, _} =
      AshEnterprise.Repo.update_all(
        Ecto.Query.from(r in "exec_agent_runs", where: r.id == type(^run.id, Ecto.UUID)),
        set: [deadline_at: past]
      )

    :ok
  end

  defp runs(ctx),
    do: Execution.list_agent_runs!(authorize?: false, tenant: ctx.tenant)

  defp text(%{content: parts}) when is_list(parts), do: Enum.map_join(parts, &(&1.text || ""))
  defp text(%{content: text}) when is_binary(text), do: text

  describe "an answer is a run" do
    test "it reads in its loop across several steps, then answers with citations", ctx do
      event = D.event!(ctx, "SYNTHETIC planning review", 60 * 24, 30)
      D.person!(ctx, "zed@example.test", "Zed Example")

      ScriptedModel.script!([
        {:tools, [{"calendar_events", %{"input" => %{"window" => "this_week"}}}]},
        {:tools, [{"find_people", %{"input" => %{"query" => "zed"}}}]},
        {:text, "You have the SYNTHETIC planning review [[calendar:#{event.id}]]."}
      ])

      assert {:ok, %Turn{} = answer} = ask(ctx, "SYNTHETIC: what is on this week?")

      assert answer.role == :assistant
      assert answer.status == :complete
      assert answer.content =~ "[[calendar:#{event.id}]]"
      assert answer.iterations == 3
      assert "calendar:#{event.id}" in answer.refs

      assert [
               %{"name" => "calendar_events", "ok" => true, "count" => 1},
               %{"name" => "find_people", "ok" => true, "count" => 1}
             ] = answer.tool_calls["calls"]

      # The answer is the run's: its id, its origin, completed, its key naming the question.
      assert [run] = runs(ctx)
      assert answer.id == run.id

      assert run.status == :completed and run.origin == :assistant and
               run.agent_key == "assistant"

      assert [%{turn: %{role: :user} = question}, %{turn: %{role: :assistant}}] =
               History.load(ctx.thread.id, F.opts(ctx)) |> elem(1) |> Map.fetch!(:turns)

      assert run.run_key =~ "assistant:#{ctx.thread.id}:#{question.id}:"

      # The in-loop read path: each lookup is a tool result in the run's journal, and
      # none is an invocation.
      assert Runs.journal(run) |> Enum.map(&elem(&1, 1)) ==
               [:assistant, :tool, :assistant, :tool, :assistant]

      assert Runs.invocations(run) == []

      # Every tool is offered, under its own name; each result went back to the model.
      assert_received {:model_request, first, tools, _opts}
      assert "calendar_events" in tools and "count_activity" in tools
      assert "compose_surface" in tools and "my_accounts" in tools
      assert "add_action_item" in tools and "merge_duplicate" in tools and length(tools) == 20
      refute Enum.any?(tools, &String.starts_with?(&1, "propose_"))
      assert Enum.any?(first, &(&1.role == :system))
      assert_received {:model_request, second, _tools, _opts}
      assert Enum.any?(second, &(&1.role == :tool and text(&1) =~ "SYNTHETIC planning review"))

      # Three model calls, each through the guard, recorded in-zone under the run's step.
      assert [_, _, _] = records = Enum.filter(calls(), &String.starts_with?(&1.caller, "run:"))
      assert Enum.all?(records, &(&1.residency == :in_zone and &1.outcome == :ok))
      assert Enum.all?(records, &(&1.zone == F.zone()))
    end

    test "its input and journal are sealed under the thread's erasure scope", ctx do
      ScriptedModel.script!([{:text, "SYNTHETIC: noted."}])
      assert {:ok, _answer} = ask(ctx, "SYNTHETIC: seal this")
      assert [run] = runs(ctx)
      assert run.erasure_scope_id == ctx.thread.erasure_scope_id
      assert {run.subject_type, run.subject_id} == {inspect(Thread), ctx.thread.id}
    end

    test "a tool error is handed back to the model, which recovers", ctx do
      ScriptedModel.script!([
        {:tools, [{"calendar_events", %{"input" => %{"window" => "SYNTHETIC-NOT-A-WINDOW"}}}]},
        {:tools, [{"no_such_tool", %{}}]},
        {:text, "SYNTHETIC: I could not read that window."}
      ])

      assert {:ok, answer} = ask(ctx, "SYNTHETIC: what happened then?")
      assert answer.status == :complete

      assert [
               %{"name" => "calendar_events", "ok" => false},
               %{"name" => "no_such_tool", "ok" => false}
             ] = answer.tool_calls["calls"]

      assert_received {:model_request, _first, _, _}
      assert_received {:model_request, second, _, _}

      assert Enum.any?(second, fn message ->
               message.role == :tool and text(message) =~ "is not a window"
             end)
    end

    test "the step limit is not lifted: the answer fails as step_cap", ctx do
      looping = {:tools, [{"pending_approvals", %{"input" => %{}}}]}
      ScriptedModel.script!(List.duplicate(looping, Ask.max_steps()))

      assert {:error, :step_cap, %Turn{status: :failed, error_class: "step_cap"} = answer} =
               ask(ctx, "SYNTHETIC: approvals?")

      assert length(answer.tool_calls["calls"]) == Ask.max_steps()
      assert [%{status: :cancelled}] = runs(ctx)
    end

    test "a model call that fails leaves the run to be tried again, not a lost answer", ctx do
      ScriptedModel.script!([
        {:error, %ReqLLM.Error.API.Request{reason: "SYNTHETIC timeout"}},
        {:text, "SYNTHETIC: back now."}
      ])

      {:ok, %{run: run}} = Ask.ask(ctx.thread, "SYNTHETIC: are you there?", F.opts(ctx))
      Runs.step!(run)

      assert {:pending, %{run: %{status: :running}}} = Ask.settle(ctx.thread, run.id, F.opts(ctx))

      Runs.elapse_lease!(run)
      Execution.recover_agent_run!(Runs.run(run), Runs.oban(ctx.tenant))

      assert {:ok, %Turn{status: :complete, content: "SYNTHETIC: back now."}} =
               F.answer!(ctx, ctx.thread, run)

      assert [%{outcome: :error}, %{outcome: :ok}] =
               calls()
               |> Enum.filter(&String.starts_with?(&1.caller, "run:"))
               |> Enum.sort_by(& &1.created_on, DateTime)
    end

    test "retry answers the same question again, as a new answer", ctx do
      ScriptedModel.script!([{:text, ""}, {:text, ""}])

      assert {:error, :empty_answer, %Turn{status: :failed}} =
               ask(ctx, "SYNTHETIC: are you there?")

      {:ok, %{turns: [question, _failed]}} = History.load(ctx.thread.id, F.opts(ctx))

      ScriptedModel.script!([{:text, "SYNTHETIC: back now."}])
      {:ok, %{run: run}} = Ask.retry(ctx.thread, question.turn, F.opts(ctx))
      assert {:ok, %Turn{status: :complete}} = F.answer!(ctx, ctx.thread, run)

      {:ok, %{turns: turns}} = History.load(ctx.thread.id, F.opts(ctx))

      assert Enum.map(turns, &{&1.turn.role, &1.turn.status}) ==
               [{:user, :complete}, {:assistant, :failed}, {:assistant, :complete}]
    end

    test "stop cancels the person's own run and records what it had", ctx do
      {:ok, %{run: run}} = Ask.ask(ctx.thread, "SYNTHETIC: tell me a long story", F.opts(ctx))

      assert :ok = Ask.stop(run.id, F.opts(ctx))

      assert {:error, :stopped, %Turn{status: :stopped}} =
               Ask.settle(ctx.thread, run.id, F.opts(ctx))

      assert Runs.run(run).status == :cancelled

      # Settling again records nothing more.
      assert {:error, :stopped, %Turn{}} = Ask.settle(ctx.thread, run.id, F.opts(ctx))
      {:ok, %{turns: turns}} = History.load(ctx.thread.id, F.opts(ctx))
      assert length(turns) == 2
    end

    test "a member stops only their own answer", ctx do
      {:ok, %{run: run}} = Ask.ask(ctx.thread, "SYNTHETIC: mine", F.opts(ctx))
      other = F.colleague!(ctx)

      assert {:error, _not_found} = Ask.stop(run.id, F.opts(other))
      assert Runs.run(run).status == :queued
    end

    test "the next question carries the conversation so far, as text only", ctx do
      ScriptedModel.script!([{:text, "SYNTHETIC-FIRST-ANSWER"}])
      assert {:ok, _} = ask(ctx, "SYNTHETIC-FIRST-QUESTION")
      assert_received {:model_request, _, _, _}

      ScriptedModel.script!([{:text, "SYNTHETIC-SECOND-ANSWER"}])
      assert {:ok, _} = ask(ctx, "SYNTHETIC-SECOND-QUESTION")
      assert_received {:model_request, messages, _, _}

      assert [{:system, _}, {:user, input}] = Enum.map(messages, &{&1.role, text(&1)})
      assert input =~ "Person: SYNTHETIC-FIRST-QUESTION"
      assert input =~ "You: SYNTHETIC-FIRST-ANSWER"
      assert input =~ "Question: SYNTHETIC-SECOND-QUESTION"
    end

    test "a thread finds the runs it has no answer for yet", ctx do
      {:ok, %{question: question, run: run}} =
        Ask.ask(ctx.thread, "SYNTHETIC: later", F.opts(ctx))

      {:ok, %{turns: entries}} = History.load(ctx.thread.id, F.opts(ctx))
      turns = Enum.map(entries, & &1.turn)
      assert [{question_id, %{id: run_id}}] = Ask.pending(ctx.thread, turns, F.opts(ctx))
      assert {question_id, run_id} == {question.id, run.id}

      ScriptedModel.script!([{:text, "SYNTHETIC: done."}])
      assert {:ok, answer} = F.answer!(ctx, ctx.thread, run)
      assert Ask.pending(ctx.thread, turns ++ [answer], F.opts(ctx)) == []
    end
  end

  describe "before a run starts" do
    test "with no in-zone profile nothing is asked: no hosted fallback", ctx do
      Application.put_env(:ash_enterprise, :ai, [])
      ScriptedModel.script!([{:text, "SYNTHETIC: must never be produced"}])

      assert {:error, :not_configured, %Turn{status: :failed}} = ask(ctx, "SYNTHETIC: hello?")

      refute_received {:model_request, _, _, _}
      assert runs(ctx) == []
      assert [%{outcome: :refused, residency: :outside_zone, caller: "assistant"}] = calls()
    end

    test "an in-zone profile outside the canonical store's zone is refused", ctx do
      F.in_zone!(profile_zone: "SYNTHETIC-OTHER-ZONE")
      ScriptedModel.script!([{:text, "SYNTHETIC: must never be produced"}])

      assert {:error, :zone_mismatch, _} = ask(ctx, "SYNTHETIC: hello?")
      refute_received {:model_request, _, _, _}
      assert runs(ctx) == []
    end

    test "a member without the start grant, or a tenant without the agent, gets a reason",
         ctx do
      colleague = F.colleague!(ctx)
      thread = F.thread!(colleague)

      assert {:error, :not_permitted, %Turn{error_class: "not_permitted"}} =
               F.ask!(colleague, thread, "SYNTHETIC: may I?")

      other = F.tenant!()

      assert {:error, :not_published, %Turn{error_class: "not_published"}} =
               F.ask!(other, F.thread!(other), "SYNTHETIC: anyone here?")
    end
  end

  describe "composing and proposing" do
    test "a composed surface is read off the journal and recorded on the call", ctx do
      ScriptedModel.script!([
        {:tools, [{"compose_surface", %{"input" => %{"show" => "tasks", "display" => "board"}}}]},
        {:text, "SYNTHETIC: your tasks are on a board."}
      ])

      assert {:ok, answer} = ask(ctx, "SYNTHETIC: board my tasks")

      assert [%{"name" => "compose_surface", "ok" => true, "surface" => surface}] =
               answer.tool_calls["calls"]

      assert %{"id" => "s" <> _, "request" => %{"show" => "tasks", "display" => "board"}} =
               surface

      # The page and the recorded answer name it alike.
      assert {:ok, %{calls: [%{"surface" => ^surface}]}} = Ask.progress(answer.id, F.opts(ctx))
    end

    test "a refused spec goes back to the model as a short reason", ctx do
      ScriptedModel.script!([
        {:tools,
         [{"compose_surface", %{"input" => %{"show" => "people", "display" => "calendar"}}}]},
        {:text, "SYNTHETIC: people cannot go on a calendar."}
      ])

      assert {:ok, answer} = ask(ctx, "SYNTHETIC: people on a calendar")
      assert [%{"name" => "compose_surface", "ok" => false} = call] = answer.tool_calls["calls"]
      refute Map.has_key?(call, "surface")

      assert_received {:model_request, _first, _, _}
      assert_received {:model_request, second, _, _}

      assert Enum.any?(second, fn message ->
               message.role == :tool and text(message) =~ "use a table"
             end)
    end

    test "a change is asked for, not made: the answer ends at the request", ctx do
      ask_to_add!(ctx)

      assert {:ok, answer} = ask(ctx, "SYNTHETIC: remind me to file the report")
      assert answer.status == :complete
      assert answer.content == "SYNTHETIC: I asked to add it; confirm it to add it."

      # The call is a request the page follows by its invocation, not a write.
      assert [%{"name" => "add_action_item", "request" => %{"id" => "r" <> _} = request}] =
               answer.tool_calls["calls"]

      assert [run] = runs(ctx)
      assert run.status == :waiting and run.blocked_on == :tools
      assert [invocation] = Runs.invocations(run)
      assert request["invocation_id"] == invocation.id
      assert invocation.status == :awaiting_approval
      assert invocation.target == "AshEnterprise.Canonical.Task.capture"
      assert invocation.owner_id == ctx.user.id
      assert Task.mine!(actor: ctx.actor, tenant: ctx.tenant) == []

      # Recording it again records it once, and it stays a request.
      assert {:ok, %{id: id}} = Ask.settle(ctx.thread, run.id, F.opts(ctx))
      assert id == answer.id
      assert [_waiting] = Runs.invocations(run)
    end

    test "confirming it runs it as the person; the run then answers once more", ctx do
      ask_to_add!(ctx)
      assert {:ok, answer} = ask(ctx, "SYNTHETIC: remind me to file the report")
      [run] = runs(ctx)
      [%{"request" => %{"invocation_id" => id}}] = answer.tool_calls["calls"]

      assert {:ok, %{status: :succeeded}} = Requests.confirm(id, ctx.actor, ctx.tenant)

      assert [%{title: "SYNTHETIC file the report", source: "assistant", owner_id: owner}] =
               Task.mine!(actor: ctx.actor, tenant: ctx.tenant)

      assert owner == ctx.user.id

      # A second confirm (another tab) finds it decided and runs nothing again.
      assert {:ok, %{status: :succeeded}} = Requests.confirm(id, ctx.actor, ctx.tenant)
      assert [_one] = Task.mine!(actor: ctx.actor, tenant: ctx.tenant)

      # The run wakes on the decision, sees the result and answers; the recorded answer
      # is the one the person already has.
      assert %{status: :completed} = wake!(run)
      assert {:ok, %{id: id_answer, content: content}} = settle(ctx, run)
      assert id_answer == answer.id
      assert content == answer.content
    end

    # The run fails at its next step, and that cancels nothing.
    test "confirmed after the run's deadline, it still runs as the person", ctx do
      ask_to_add!(ctx)
      assert {:ok, answer} = ask(ctx, "SYNTHETIC: remind me to file the report")
      [run] = runs(ctx)
      [%{"request" => %{"invocation_id" => id}}] = answer.tool_calls["calls"]

      deadline_passes!(run)

      assert {:ok, %{status: :succeeded}} = Requests.confirm(id, ctx.actor, ctx.tenant)
      assert [%{source: "assistant"}] = Task.mine!(actor: ctx.actor, tenant: ctx.tenant)

      # Its next step finds the deadline passed: the run fails, and the request stands.
      _ = Runs.step!(Runs.run(run))
      assert %{status: :failed, error_code: "deadline_passed"} = Runs.run(run)
      assert [%{status: :succeeded}] = Runs.invocations(run)
    end

    test "declining it runs nothing, and the run hears why", ctx do
      ask_to_add!(ctx)
      assert {:ok, answer} = ask(ctx, "SYNTHETIC: remind me to file the report")
      [run] = runs(ctx)
      [%{"request" => %{"invocation_id" => id}}] = answer.tool_calls["calls"]

      assert {:ok, %{status: :rejected, error_code: "approval_rejected"}} =
               Requests.decline(id, ctx.actor, ctx.tenant)

      assert Task.mine!(actor: ctx.actor, tenant: ctx.tenant) == []
      assert %{status: :completed} = wake!(run)
      assert_received {:model_request, _first, _, _}
      assert_received {:model_request, second, _, _}

      assert Enum.any?(second, fn message ->
               message.role == :tool and text(message) =~ "approval_rejected"
             end)
    end

    test "a request names only the person's own", ctx do
      ask_to_add!(ctx)
      assert {:ok, answer} = ask(ctx, "SYNTHETIC: remind me to file the report")
      [%{"request" => %{"invocation_id" => id}}] = answer.tool_calls["calls"]
      colleague = F.colleague!(ctx)

      assert :error = Requests.get(id, colleague.actor, ctx.tenant)
      assert {:error, :not_found} = Requests.confirm(id, colleague.actor, ctx.tenant)
      assert Task.mine!(actor: ctx.actor, tenant: ctx.tenant) == []
      assert {:ok, %{status: :awaiting_approval}} = Requests.get(id, ctx.actor, ctx.tenant)
    end
  end
end
