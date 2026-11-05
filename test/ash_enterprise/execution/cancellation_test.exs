defmodule AshEnterprise.Execution.CancellationTest do
  @moduledoc """
  Invariant 5, explicit cancellation (ADR 0056): cancelling a run stops its future
  steps and cancels its tool calls that have not started. What already ran stays as it
  ran: nothing is undone, and no compensating work is started on the run's behalf;
  reversing an effect is a separate request a person makes.

  Committed for real, with a real Oban whose queues are paused so the test drains them by
  hand.
  """

  use AshEnterprise.DurabilityCase, async: false

  import AshEnterprise.Test.Execution.Runs

  alias AshAgent.Invocation.Executor
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Invocation
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

  test "one succeeded and one ready invocation: the ready one is cancelled, the succeeded one stays, nothing is undone",
       %{clinic: %{nurse: nurse, admin: admin, tenant: tenant}} do
    n = System.unique_integer([:positive])
    done = "SYNTHETIC: send the discharge summary #{n}"
    pending = "SYNTHETIC: order the follow-up panel #{n}"

    script!([
      {:tools, [record_call("call_done", done), record_call("call_pending", pending)]},
      {:text, ~s({"recorded": 2})}
    ])

    {:ok, run} = start(nurse)
    assert %{failure: 0} = Oban.drain_queue(queue: :agent_runs)

    [first, second] = invocations(run)
    assert {:ok, :succeeded} = Executor.execute(Invocation, first.id, oban(tenant))
    assert %{status: :ready} = Execution.get_invocation!(second.id, oban(tenant))

    # An administrator cancels the run.
    assert {:ok, cancelled} =
             Execution.request_agent_run_cancel(run(run), actor: admin.actor, tenant: tenant)

    assert cancelled.status == :cancelled
    assert cancelled.cancel_requested_at

    assert [
             %{invocation_key: "run:" <> _, status: :succeeded},
             %{status: :cancelled}
           ] = invocations(run)

    # Whatever jobs were queued run now: the cancelled call never runs, the run never
    # steps again, and the call that ran is not reversed.
    assert %{failure: 0} = Oban.drain_queue(queue: :execution)
    assert %{failure: 0} = Oban.drain_queue(queue: :agent_runs)

    assert {notes(tenant, done), notes(tenant, pending)} == {1, 0}
    assert length(invocations(run)) == 2
    assert model_calls(run) == [{"run:#{run.id}:1", :ok}]
    assert run(run).status == :cancelled
  end

  test "cancelling is by grant: a member who holds no role cannot cancel even their own run",
       %{clinic: %{nurse: nurse}} do
    {:ok, run} = start(nurse)

    assert {:error, %Ash.Error.Forbidden{}} =
             Execution.request_agent_run_cancel(run(run),
               actor: nurse.actor,
               tenant: nurse.tenant
             )

    assert run(run).status == :queued
  end
end
