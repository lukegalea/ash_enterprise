defmodule AshEnterprise.Assistant.DurableAnswerTest do
  @moduledoc """
  An answer outlives the worker answering it (AGT-33): the assistant's answer is a
  durable run, so a worker killed mid-answer leaves a run to resume, not a lost turn.
  The thread still holds the question and knows its run; once the run's lease runs out
  the sweep queues it again, the resumed step reads what the journal already has, and
  the answer is recorded as if nothing had happened.

  Committed for real, with a real Oban whose `:agent_runs` queue is paused: the test
  drains it by hand. The model is the scripted stand-in behind the guarded ReqLLM
  module; nothing reaches a network.
  """

  use AshEnterprise.DurabilityCase, async: false

  import AshEnterprise.Test.Execution.Runs

  alias AshEnterprise.Assistant.{Ask, History, Turn}
  alias AshEnterprise.Execution.Run.RecoverScheduler
  alias AshEnterprise.Test.AssistantFixtures, as: F

  setup do
    in_zone!()
    pause_queues!()
    ctx = F.tenant!()
    F.published!(ctx)
    Map.put(ctx, :thread, F.thread!(ctx))
  end

  defp drain(opts \\ []), do: Oban.drain_queue(Keyword.merge([queue: :agent_runs], opts))

  test "a worker killed mid-answer leaves a run to resume, and the answer is recorded once",
       ctx do
    script!([
      {:tools, [{"pending_approvals", %{"input" => %{}}}]},
      {:exit, :killed},
      {:text, "SYNTHETIC: nothing is waiting on you."}
    ])

    {:ok, %{question: question, run: run}} =
      Ask.ask(ctx.thread, "SYNTHETIC: what waits on me?", F.opts(ctx))

    # The first step: the model reads in its loop. No invocation; the run goes on.
    assert %{failure: 0} = drain()
    assert %{status: :queued} = run(run)
    assert journal(run) == [{1, :assistant}, {2, :tool}]

    # That step enqueued the next from inside its own job: no sweep is waited for.
    assert [_next] = step_jobs(run)

    # The next step's worker dies inside its model call.
    assert %{failure: 1} = drain()
    assert %{status: :running} = run(run)

    # Not a lost turn: the thread holds the question, knows the run still answering it,
    # and has no answer yet.
    assert {:pending, %{calls: [%{"name" => "pending_approvals", "ok" => true}]}} =
             Ask.settle(ctx.thread, run.id, F.opts(ctx))

    {:ok, %{turns: entries}} = History.load(ctx.thread.id, F.opts(ctx))
    turns = Enum.map(entries, & &1.turn)
    assert [%Turn{role: :user}] = turns
    assert [{question_id, %{id: run_id}}] = Ask.pending(ctx.thread, turns, F.opts(ctx))
    assert {question_id, run_id} == {question.id, run.id}

    # Once the lease runs out the sweep queues the run again, and its step resumes.
    elapse_lease!(run)
    Oban.insert!(RecoverScheduler.new(%{}))
    assert %{failure: 0} = drain(with_recursion: true)
    assert %{status: :queued} = run(run)

    assert [next] = step_jobs(run)
    :ok = Oban.retry_job(next.id)
    assert %{failure: 0} = drain()
    assert %{status: :completed} = run(run)

    # The resumed step read the lookup off the journal: it was not run again.
    assert journal(run) == [{1, :assistant}, {2, :tool}, {3, :assistant}]
    assert invocations(run) == []

    assert {:ok, %Turn{status: :complete} = answer} = Ask.settle(ctx.thread, run.id, F.opts(ctx))
    assert answer.id == run.id
    assert answer.content == "SYNTHETIC: nothing is waiting on you."
    assert [%{"name" => "pending_approvals", "ok" => true}] = answer.tool_calls["calls"]

    # Settled again, nothing more is recorded.
    assert {:ok, %Turn{id: id}} = Ask.settle(ctx.thread, run.id, F.opts(ctx))
    assert id == run.id
    {:ok, %{turns: entries}} = History.load(ctx.thread.id, F.opts(ctx))
    assert Enum.map(entries, & &1.turn.role) == [:user, :assistant]

    # The call the dead worker made and its repeat are both on record, under one name.
    assert [{one, :ok}, {three, :error}, {three, :ok}] = model_calls(run)
    assert one == "run:#{run.id}:1" and three == "run:#{run.id}:3"
  end
end
