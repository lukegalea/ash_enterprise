defmodule AshEnterprise.Execution.ReconcileTest do
  @moduledoc """
  Reconciliation (ADR 0055, failure scenario F2): an outside call is at least once, so an
  acknowledgement lost on the way back never leads to a blind retry. The row becomes
  `outcome_unknown` and is settled by the target's `reconcile_with` lookup, or waits for
  a person; an internal target's expired lease, whose effect rolled back with it, is
  simply made ready again.

  The outside board is `AshEnterprise.Test.Execution.FakeBoard` behind the Nango façade,
  shared with every process so real `:execute` and `:reconcile` jobs reach it. A worker
  is killed at the fault point `:referral_accepted`, between the board taking the
  referral and anything being recorded.
  """

  use AshEnterprise.DurabilityCase, async: false

  import AshEnterprise.Test.Execution.Durable

  alias AshAgent.Invocation.Executor
  alias AshEnterprise.Execution.Invocation.{ExecuteWorker, ReconcileScheduler, ReconcileWorker}
  alias AshEnterprise.Execution.Resolution
  alias AshEnterprise.Test.Execution.FakeBoard

  require Ash.Query

  setup do
    FakeBoard.start!()
    subscribe_jobs()
    clinic!()
  end

  # The worker running `row`'s `:execute` job is killed right after the board took the
  # referral: the effect happened, and nothing recorded it.
  defp killed_after_accept!(row) do
    [job] = jobs(row.id)
    assert_receive {:fault_fired, :referral_accepted, _worker}, 10_000
    assert %{kind: :exit} = await_job(job.id, :failure)
    job
  end

  # Runs now whatever `:execute` job `row` has pending: a fresh one, or the killed
  # worker's job waiting out Oban's retry backoff (which holds `requeue`'s new job back:
  # ash_oban keeps one incomplete job per row and trigger).
  defp run_pending_execute!(row) do
    pending =
      for job <- jobs(row.id, ExecuteWorker),
          job.state in ~w(available scheduled retryable),
          do: job

    assert pending != []

    for job <- pending do
      :ok = Oban.retry_job(job.id)
      await_job(job.id, :success)
    end
  end

  # The reconcile sweep, as its cron would run it, and the job it enqueues for `row`.
  defp sweep_reconcile!(row) do
    sweep = Oban.insert!(ReconcileScheduler.new(%{}))
    await_job(sweep.id, :success)
    assert [job | _] = jobs(row.id, ReconcileWorker)
    await_job(job.id, :success)
  end

  test "a connector accepts and the worker is killed: the row is reconciled, the connector called once",
       %{nurse: nurse, tenant: tenant} do
    Faults.arm(:referral_accepted, :kill, notify: self())
    {:ok, row} = refer(nurse, :refer)
    killed_after_accept!(row)

    # The worker is gone holding the lease. Nothing runs the row again, and when the
    # lease runs out it is not taken over: that would refer the patient twice.
    held = committed(row.id, tenant)
    assert {held.status, held.lease_epoch} == {:executing, 1}
    elapse!(row, :lease_expires_at)
    assert {:error, :not_claimable} = Executor.claim(committed(row.id, tenant), oban(tenant))

    sweep_reconcile!(row)

    done = committed(row.id, tenant)
    assert {done.status, done.reconciled_via} == {:succeeded, "reconcile_with"}
    assert done.effect_system == "referral-board"
    assert {FakeBoard.calls(), FakeBoard.referrals()} == {1, 1}
  end

  test "with no lookup the row ends outcome_unknown and waits for a person, the connector called once",
       %{nurse: nurse, tenant: tenant} do
    Faults.arm(:referral_accepted, :kill, notify: self())
    {:ok, row} = refer(nurse, :refer_unchecked)
    killed_after_accept!(row)
    elapse!(row, :lease_expires_at)

    sweep_reconcile!(row)

    unknown = committed(row.id, tenant)
    assert {unknown.status, unknown.error_code} == {:outcome_unknown, "lease_expired"}
    assert %DateTime{} = unknown.resolution_requested_at

    key = Resolution.key()
    id = row.id

    assert [%{status: :open}] =
             AshEnterprise.Bpmn.HumanTask
             |> Ash.Query.filter(subject_id == ^id and node_id == ^key)
             |> Ash.read!(authorize?: false, tenant: tenant)

    assert FakeBoard.calls() == 1
  end

  test "a lost acknowledgement on the call itself is unknown at once, then reconciled",
       %{nurse: nurse, tenant: tenant} do
    FakeBoard.mode(:lose_ack)
    {:ok, row} = refer(nurse, :refer)
    [job] = jobs(row.id)
    await_job(job.id, :success)

    # `mark_outcome_unknown` enqueued the reconcile job in its own transaction.
    assert [reconcile] = jobs(row.id, ReconcileWorker)
    await_job(reconcile.id, :success)

    done = committed(row.id, tenant)
    assert {done.status, done.reconciled_via} == {:succeeded, "reconcile_with"}
    assert FakeBoard.calls() == 1
  end

  test "an internal target whose worker died with the lease is re-readied, not unknown",
       %{nurse: nurse, tenant: tenant} do
    pause_execution!()
    title = "Restock the suture kits #{System.unique_integer([:positive])}"
    {:ok, row} = invoke(nurse, record_target(), %{"title" => title}, "note:#{title}")

    # A worker claims and dies before its transaction commits: nothing of its effect is
    # left, its job is gone, and its lease runs out.
    [first] = jobs(row.id)
    {:ok, _claimed} = Executor.claim(row, oban(tenant), lease_for: 0)
    :ok = Oban.cancel_job(first.id)
    Oban.resume_queue(queue: :execution)

    sweep_reconcile!(row)

    # Ready again, with an `:execute` job enqueued by `requeue`, which runs it once.
    assert [_first, again] = jobs(row.id, ExecuteWorker)
    await_job(again.id, :success)

    done = committed(row.id, tenant)
    assert {done.status, done.lease_epoch, done.reconciled_via} == {:succeeded, 2, nil}
    assert effects(tenant, title) == 1
  end

  test "an idempotent connector is called again with the same key and takes it once",
       %{nurse: nurse, tenant: tenant} do
    Faults.arm(:referral_accepted, :kill, notify: self())
    {:ok, row} = refer(nurse, :refer_keyed)
    killed_after_accept!(row)
    elapse!(row, :lease_expires_at)

    sweep_reconcile!(row)
    assert committed(row.id, tenant).status == :ready
    run_pending_execute!(row)

    assert committed(row.id, tenant).status == :succeeded
    assert {FakeBoard.calls(), FakeBoard.referrals()} == {2, 1}
  end
end
