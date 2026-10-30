defmodule AshEnterprise.Execution.TypedFailureTest do
  @moduledoc """
  Invariant 6, typed failure (ADR 0055): every way a governed invocation's target can
  fail, run through real `:execute` jobs, against the state the row ends in, whether it
  is tried again, and what a process that ran it would see
  (`AshAgent.Invocation.Failure.bpmn/1`).

  | Case | State | Class | Tried again? | A process sees |
  |---|---|---|---|---|
  | principal deactivated before the claim | failed | `:denied` | no | an incident |
  | subject gone before the run | failed | `:rejected` | no | an incident |
  | the clinic's rule refuses | failed | `:business` | no | business error `declined_by_clinic` |
  | the board is busy (429) | ready, after a backoff | `:transient` | yes, until `max_attempts`; then failed, and `retry` may | waits; then an incident |
  | the board refuses the request (400) | failed | `:permanent` | no | an incident |
  | the acknowledgement is lost (502), not idempotent | outcome_unknown | — | never blindly; reconciled | waits |
  | the acknowledgement is lost (502), idempotent | ready, after a backoff | `:transient` | yes, same key | waits |
  | a dispatch's deadline passes, idempotent | failed | `:timeout` | no | an incident |

  The outside board is `AshEnterprise.Test.Execution.FakeBoard` behind the Nango façade,
  so the provider edge's own error (`ProxyError`) is what gets classified.
  """

  use AshEnterprise.DurabilityCase, async: false

  import AshEnterprise.Test.Execution.Durable
  import Ecto.Query, only: [from: 2]

  alias AshAgent.Invocation.{Executor, Failure}
  alias AshEnterprise.Execution
  alias AshEnterprise.Test.DailyFixtures
  alias AshEnterprise.Test.Execution.{ClinicNote, FakeBoard}

  setup do
    FakeBoard.start!()
    subscribe_jobs()
    clinic!()
  end

  # Runs `row`'s `:execute` job and returns the row as it committed.
  defp ran(row, tenant) do
    [job | _] = jobs(row.id)
    await_job(job.id, :success)
    committed(row.id, tenant)
  end

  defp unique, do: System.unique_integer([:positive])

  defp note!(member, title) do
    Ash.create!(ClinicNote, %{title: title},
      action: :record,
      actor: member.actor,
      tenant: member.tenant
    )
  end

  defp final?(row, tenant) do
    assert {:error, _} = Execution.retry_invocation(row, oban(tenant))
  end

  test "a principal who lost their authority before the claim: denied, final",
       %{admin: admin, tenant: tenant} do
    pause_execution!()
    member = DailyFixtures.member!(admin, "Locum #{unique()}", [])
    title = "Chase the pathology report #{unique()}"
    {:ok, row} = invoke(member, record_target(), %{"title" => title}, "deny:#{unique()}")

    DailyFixtures.deactivate!(member)
    Oban.resume_queue(queue: :execution)

    failed = ran(row, tenant)
    assert {failed.status, failed.failure_class} == {:failed, :denied}
    assert failed.error_code =~ "no_authority"
    assert {:error, {:incident, :denied, _}} = Failure.bpmn(failed)
    assert effects(tenant, title) == 0
    final?(failed, tenant)
  end

  test "a subject gone before the run: rejected, final", %{nurse: nurse, tenant: tenant} do
    pause_execution!()
    note = note!(nurse, "Update the rota #{unique()}")

    {:ok, row} =
      invoke(
        nurse,
        "AshEnterprise.Test.Execution.ClinicNote.retitle",
        %{"id" => note.id, "title" => "Update the weekend rota"},
        "gone:#{unique()}"
      )

    assert row.status == :ready

    # The note is gone by the time the job runs. Deleted past the actions: the test
    # target has no destroy.
    {1, _} =
      Repo.delete_all(from(t in "canonical_tasks", where: t.id == type(^note.id, Ecto.UUID)))

    Oban.resume_queue(queue: :execution)

    failed = ran(row, tenant)
    assert {failed.status, failed.failure_class} == {:failed, :rejected}
    assert {:error, {:incident, :rejected, _}} = Failure.bpmn(failed)
    final?(failed, tenant)
  end

  test "the clinic's rule refuses: business, final, and a process can route on the code",
       %{nurse: nurse, tenant: tenant} do
    title = "DECLINED: cosmetic referral #{unique()}"

    {:ok, row} =
      invoke(
        nurse,
        "AshEnterprise.Test.Execution.ClinicNote.record_screened",
        %{"title" => title},
        "rule:#{unique()}"
      )

    failed = ran(row, tenant)

    assert {failed.status, failed.failure_class, failed.error_code} ==
             {:failed, :business, "declined_by_clinic"}

    assert Failure.bpmn(failed) == {:error, {:bpmn_error, "declined_by_clinic", %{}}}
    assert effects(tenant, title) == 0
    final?(failed, tenant)
  end

  test "a busy board: transient, tried again after a backoff, then final, then retried on purpose",
       %{nurse: nurse, tenant: tenant} do
    FakeBoard.mode(:busy)
    {:ok, row} = refer(nurse, :refer)

    deferred = ran(row, tenant)

    assert {deferred.status, deferred.failure_class, deferred.error_code} ==
             {:ready, :transient, "rate_limited"}

    assert DateTime.compare(deferred.next_attempt_at, DateTime.utc_now()) == :gt
    assert Failure.bpmn(deferred) == :waiting

    # Not before its time: the claim refuses it.
    assert {:error, :not_claimable} = Executor.claim(deferred, oban(tenant))

    # Attempts two and three, as the sweep would run them once their time comes.
    for _attempt <- 2..3 do
      elapse!(row, :next_attempt_at)
      assert {:ok, _} = Executor.execute(Execution.Invocation, row.id, oban(tenant))
    end

    failed = committed(row.id, tenant)
    assert {failed.status, failed.failure_class, failed.attempt_count} == {:failed, :transient, 3}
    assert {:error, {:incident, :transient, "rate_limited"}} = Failure.bpmn(failed)
    # One call per attempt: the board asks for a minute, longer than the façade waits.
    assert FakeBoard.calls() == 3

    # Only a transient failure may be retried, and only on purpose.
    FakeBoard.mode(:accept)
    assert %{status: :ready} = Execution.retry_invocation!(failed, oban(tenant))
    assert [_first, again] = jobs(row.id)
    await_job(again.id, :success)
    assert committed(row.id, tenant).status == :succeeded
  end

  test "a refused request: permanent, final", %{nurse: nurse, tenant: tenant} do
    FakeBoard.mode(:reject)
    {:ok, row} = refer(nurse, :refer)

    failed = ran(row, tenant)

    assert {failed.status, failed.failure_class, failed.error_code} ==
             {:failed, :permanent, "bad_request"}

    assert {:error, {:incident, :permanent, "bad_request"}} = Failure.bpmn(failed)
    assert FakeBoard.calls() == 1
    final?(failed, tenant)
  end

  test "a lost acknowledgement on a call that is not idempotent: unknown, never sent again",
       %{nurse: nurse, tenant: tenant} do
    FakeBoard.mode(:lose_ack)
    {:ok, row} = refer(nurse, :refer_unchecked)

    unknown = ran(row, tenant)
    assert {unknown.status, unknown.error_code} == {:outcome_unknown, "server_error"}
    assert Failure.bpmn(unknown) == :waiting
    assert {:error, :not_claimable} = Executor.claim(unknown, oban(tenant))
    assert FakeBoard.calls() == 1
  end

  test "a lost acknowledgement on an idempotent call: transient, tried again with the same key",
       %{nurse: nurse, tenant: tenant} do
    FakeBoard.mode(:lose_ack)
    {:ok, row} = refer(nurse, :refer_keyed)

    deferred = ran(row, tenant)
    assert {deferred.status, deferred.failure_class} == {:ready, :transient}

    FakeBoard.mode(:accept)
    elapse!(row, :next_attempt_at)
    assert {:ok, :succeeded} = Executor.execute(Execution.Invocation, row.id, oban(tenant))
    assert {FakeBoard.calls(), FakeBoard.referrals()} == {2, 1}
  end

  test "a dispatch whose deadline passes, on idempotent work: timeout, final",
       %{nurse: nurse, tenant: tenant} do
    {:ok, row} = refer(nurse, :refer_later_keyed)

    dispatched = ran(row, tenant)

    assert {dispatched.status, dispatched.lease_expires_at, dispatched.effect_system} ==
             {:dispatched, nil, "referral-board"}

    assert Failure.bpmn(dispatched) == :waiting

    elapse!(row, :deadline_at)
    assert :failed = Execution.reconcile_invocation!(%{"id" => row.id}, oban(tenant))

    failed = committed(row.id, tenant)

    assert {failed.status, failed.failure_class, failed.reconciled_via} ==
             {:failed, :timeout, "deadline"}

    assert {:error, {:incident, :timeout, "deadline_passed"}} = Failure.bpmn(failed)
    final?(failed, tenant)
  end
end
