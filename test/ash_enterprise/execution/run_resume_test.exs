defmodule AshEnterprise.Execution.RunResumeTest do
  @moduledoc """
  A durable agent run survives its worker (ADR 0056, failure scenario F1): a step is
  claimed before its model call, every tool call that is not an in-loop read runs once
  as an invocation, and a step repeated after its worker died reads what was recorded
  instead of doing anything again.

  Committed for real, with a real Oban whose `:agent_runs` and `:execution` queues are
  paused: each test drains them by hand, so every job runs when the test says. The model
  is the scripted stand-in behind the guarded ReqLLM module; nothing reaches a network.
  """

  use AshEnterprise.DurabilityCase, async: false

  import AshEnterprise.Test.Execution.Runs

  alias AshAgent.Run.Stepper
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Run.RecoverScheduler
  alias AshEnterprise.Test.AssistantFixtures
  alias AshEnterprise.Test.Execution, as: Notes

  setup do
    in_zone!()
    pause_queues!()
    clinic = clinic!()
    published!(clinic)
    %{clinic: clinic}
  end

  defp notes(tenant, title),
    do:
      length(
        Notes.list_notes!(query: [filter: [title: title]], tenant: tenant, authorize?: false)
      )

  defp drain(queue, opts \\ []),
    do: Oban.drain_queue(Keyword.merge([queue: queue], opts))

  defp tool_results(messages), do: for(%{role: :tool} = m <- messages, do: m.tool_call_id)

  defp user_step(text), do: %{role: :user, parts: [%{"type" => "text", "text" => text}]}

  defp record_step(run, input) do
    run
    |> Ash.Changeset.for_update(
      :record_step,
      Map.merge(%{epoch: run.lease_epoch, outcome: :running}, input),
      oban(run.organization_id)
    )
    |> Ash.update()
  end

  test "a worker that dies after two tools completed: the next job reuses both results and runs nothing again",
       %{clinic: %{nurse: nurse, tenant: tenant}} do
    n = System.unique_integer([:positive])
    pharmacy = "SYNTHETIC: ask the pharmacy about the refill #{n}"
    interpreter = "SYNTHETIC: book the interpreter #{n}"

    script!([
      {:tools, [record_call("call_pharmacy", pharmacy), record_call("call_interp", interpreter)]},
      {:exit, :killed},
      {:text, ~s({"recorded": 2})}
    ])

    {:ok, run} = start(nurse)

    # The first step: the model asks for two tools; both are requested, neither run.
    assert %{failure: 0} = drain(:agent_runs)
    assert_receive {:model_request, _messages, _tools, _opts}
    assert %{status: :waiting, blocked_on: :tools} = run(run)

    # Both tools complete.
    assert %{failure: 0} = drain(:execution)
    assert {notes(tenant, pharmacy), notes(tenant, interpreter)} == {1, 1}

    # The next job records both results, calls the model, and its worker dies mid-call.
    assert %{failure: 1} = drain(:agent_runs)
    assert_receive {:model_request, messages, _tools, _opts}
    assert tool_results(messages) == ["call_pharmacy", "call_interp"]

    held = run(run)
    assert held.status == :running
    assert journal(run) == [{1, :assistant}, {2, :tool}, {3, :tool}]

    # Nothing takes the run over while its lease holds; once it runs out, the sweep
    # queues it again. The dead worker's job is the run's next job (ash_oban keeps one
    # incomplete job per run and trigger): it runs now, as its retry backoff would.
    assert :skipped = step!(run)
    elapse_lease!(run)
    Oban.insert!(RecoverScheduler.new(%{}))
    assert %{failure: 0} = drain(:agent_runs, with_recursion: true)
    assert %{status: :queued} = run(run)

    assert [next] = step_jobs(run)
    :ok = Oban.retry_job(next.id)
    assert %{failure: 0} = drain(:agent_runs)

    # The resumed step read both results from the journal: no tool ran again.
    assert_receive {:model_request, messages, _tools, _opts}
    assert tool_results(messages) == ["call_pharmacy", "call_interp"]

    done = run(run)
    assert done.status == :completed
    assert done.lease_epoch == held.lease_epoch + 1
    assert journal(run) == [{1, :assistant}, {2, :tool}, {3, :tool}, {4, :assistant}]
    assert {notes(tenant, pharmacy), notes(tenant, interpreter)} == {1, 1}

    for call <- invocations(run) do
      assert {call.status, call.attempt_count, call.lease_epoch} == {:succeeded, 1, 1}
    end

    # The call the dead worker made and its repeat are both on record, under one name.
    assert model_calls(run) == [
             {"run:#{run.id}:1", :ok},
             {"run:#{run.id}:4", :error},
             {"run:#{run.id}:4", :ok}
           ]
  end

  test "an append from a worker whose lease was taken over, or from a stale copy, is refused",
       %{clinic: %{nurse: nurse}} do
    {:ok, run} = start(nurse)

    # A claims, and its lease runs out before it records anything.
    {:ok, a} = Stepper.claim(run(run), oban(run.organization_id), lease_for: 0)
    {:ok, queued} = Execution.recover_agent_run(run(run), oban(run.organization_id))
    {:ok, b} = Stepper.claim(queued, oban(run.organization_id))
    assert b.lease_epoch == a.lease_epoch + 1

    # A's append is refused, and nothing it said reaches the journal.
    assert {:error, _superseded} = record_step(a, %{steps: [user_step("SYNTHETIC: from A")]})
    assert journal(run) == []

    # B appends; the same append again, from the copy B read before it, is refused too.
    assert {:ok, _recorded} = record_step(b, %{steps: [user_step("SYNTHETIC: from B")]})
    assert {:error, _stale} = record_step(b, %{steps: [user_step("SYNTHETIC: again")]})
    assert journal(run) == [{1, :user}]
  end

  test "a duplicate job makes one model call", %{clinic: %{nurse: nurse}} do
    script!([{:text, ~s({"recorded": 0})}, {:text, ~s({"recorded": "twice"})}])
    {:ok, run} = start(nurse)

    outcomes = race(2, fn _ -> step!(run) end)

    assert Enum.sort(outcomes) == [:completed, :skipped]
    assert model_calls(run) == [{"run:#{run.id}:1", :ok}]
    assert journal(run) == [{1, :assistant}]
  end

  test "a requester without the agent's start grant is refused, and no run is written",
       %{clinic: clinic} do
    stranger = AssistantFixtures.colleague!(clinic.admin, [])

    assert {:error, %Ash.Error.Forbidden{}} = start(stranger)

    assert Execution.list_agent_runs!(
             query: [filter: [owner_id: stranger.user.id]],
             authorize?: false,
             tenant: clinic.tenant
           ) == []
  end

  test "an answer that never casts stops after max_repairs, failed as rejected",
       %{clinic: %{nurse: nurse}} do
    script!([
      {:text, "SYNTHETIC: two notes, I think"},
      {:text, "SYNTHETIC: still not an object"},
      {:text, ~s({"recorded": "never asked"})}
    ])

    {:ok, run} = start(nurse)

    # The version allows one repair turn: the run asks again, saying what was wrong.
    assert :queued = step!(run)
    assert :failed = step!(run)

    failed = run(run)
    assert {failed.failure_class, failed.error_code} == {:rejected, "output_uncastable"}
    assert {failed.repair_count, failed.step_count} == {1, 2}
    assert journal(run) == [{1, :assistant}, {2, :user}, {3, :assistant}]

    # A failed run takes no further step.
    assert :skipped = step!(run)
    assert length(model_calls(run)) == 2
  end
end
