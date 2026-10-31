defmodule AshEnterprise.Execution.WakeupTest do
  @moduledoc """
  Invariant 9, reliable wake-up (ADR 0056): a run waiting on its tool calls is woken by
  each one that finishes, in that invocation's own transaction, and whether it has a
  step to take is derived (`needs_step`), never counted. However many wake-ups arrive
  and however many jobs act on them at once, the run steps once; a completion delivered
  again wakes nothing; a wake-up that was lost costs a sweep's delay, never the run.

  Committed for real, with a real Oban whose queues are paused so each test drains them
  by hand.
  """

  use AshEnterprise.DurabilityCase, async: false

  import AshEnterprise.Test.Execution.Runs

  alias AshAgent.Invocation.Executor
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Invocation
  alias AshEnterprise.Execution.Run.StepScheduler

  setup do
    in_zone!()
    pause_queues!()
    clinic = clinic!()
    published!(clinic)
    %{clinic: clinic}
  end

  # A run whose first step asked for two tools, both requested and ready.
  defp waiting_on_two!(nurse) do
    n = System.unique_integer([:positive])

    script!([
      {:tools,
       [
         record_call("call_a", "SYNTHETIC: chase the lab #{n}"),
         record_call("call_b", "SYNTHETIC: call the family #{n}")
       ]},
      {:text, ~s({"recorded": 2})}
    ])

    {:ok, run} = start(nurse)
    assert %{failure: 0} = Oban.drain_queue(queue: :agent_runs)
    assert %{status: :waiting, blocked_on: :tools} = run(run)
    assert [_a, _b] = invocations(run)
    run
  end

  test "two invocations of one step complete concurrently; the run steps once",
       %{clinic: %{nurse: nurse, tenant: tenant}} do
    run = waiting_on_two!(nurse)
    [a, b] = invocations(run)

    # Both finish at the same moment, each waking the run in its own transaction.
    assert race(2, fn i -> Executor.execute(Invocation, Enum.at([a, b], i).id, oban(tenant)) end) ==
             [{:ok, :succeeded}, {:ok, :succeeded}]

    assert step_jobs(run) != []

    # Several jobs act on the wake-ups at once: one claims the step, the rest find
    # nothing to do.
    outcomes = race(3, fn _ -> step!(run) end)
    assert Enum.count(outcomes, &(&1 == :completed)) == 1
    assert Enum.count(outcomes, &(&1 == :skipped)) == 2

    # The wake-up jobs still queued end without a model call.
    assert %{failure: 0} = Oban.drain_queue(queue: :agent_runs)
    assert model_calls(run) == [{"run:#{run.id}:1", :ok}, {"run:#{run.id}:4", :ok}]
    assert run(run).status == :completed
  end

  test "a replayed completion does nothing", %{clinic: %{nurse: nurse, tenant: tenant}} do
    run = waiting_on_two!(nurse)
    [a, b] = invocations(run)
    assert {:ok, :succeeded} = Executor.execute(Invocation, a.id, oban(tenant))

    # The first completion woke the run, but its other call is still open: it waits.
    assert %{failure: 0} = Oban.drain_queue(queue: :agent_runs)
    before = run(run)
    assert {before.status, before.lease_epoch} == {:waiting, 1}

    # The finished invocation's job delivered again claims nothing and wakes nothing.
    assert :skipped = Execution.execute_invocation!(%{"id" => a.id}, oban(tenant))
    assert step_jobs(run) == []

    # A wake-up delivered again, for a run with nothing to do, makes no model call.
    AshAgent.Run.Enqueue.wake(AshEnterprise.Execution.Run, run.id, tenant)
    assert %{failure: 0} = Oban.drain_queue(queue: :agent_runs)
    assert run(run).lease_epoch == before.lease_epoch
    assert length(model_calls(run)) == 1

    # The second completion wakes it, and it steps once.
    assert {:ok, :succeeded} = Executor.execute(Invocation, b.id, oban(tenant))
    assert %{failure: 0} = Oban.drain_queue(queue: :agent_runs)
    assert run(run).status == :completed
    assert length(model_calls(run)) == 2
  end

  test "a lost wake-up is found by the sweep", %{clinic: %{nurse: nurse, tenant: tenant}} do
    run = waiting_on_two!(nurse)

    for call <- invocations(run),
        do: assert({:ok, :succeeded} = Executor.execute(Invocation, call.id, oban(tenant)))

    # The wake-up jobs are lost.
    for job <- step_jobs(run), do: :ok = Oban.cancel_job(job.id)
    assert step_jobs(run) == []
    assert run(run).status == :waiting

    # The `:step` sweep finds the run that has a step to take, and it completes.
    Oban.insert!(StepScheduler.new(%{}))
    assert %{failure: 0} = Oban.drain_queue(queue: :agent_runs, with_recursion: true)
    assert run(run).status == :completed
  end
end
