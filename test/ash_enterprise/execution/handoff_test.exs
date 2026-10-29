defmodule AshEnterprise.Execution.HandoffTest do
  @moduledoc """
  Invariant 1, atomic durable handoff (ADR 0055): a ready invocation and its `:execute`
  job commit in one transaction, and a sweep picks up a ready row whose job was lost.

    * A requester killed the instant its request committed leaves a ready row whose job
      runs anyway.
    * A fault inside the request's transaction, after its job was inserted, rolls both
      back: no row, and no job for one.
    * A ready row with no job (the job was lost) is matched by the trigger's scheduler,
      which enqueues it again.

  The fault points are `AshEnterprise.Execution.Changes.HandoffFaultPoints`.
  """

  use AshEnterprise.DurabilityCase, async: false

  import AshEnterprise.Test.Execution.Durable

  require Ash.Query

  alias AshEnterprise.Execution.Invocation
  alias AshEnterprise.Execution.Invocation.{ExecuteScheduler, ExecuteWorker}

  setup do
    subscribe_jobs()
    clinic!()
  end

  test "a requester killed right after the commit still has its job run", %{nurse: nurse} do
    unique = System.unique_integer([:positive])
    key = "handoff:#{unique}"
    title = "Book the interpreter #{unique}"

    Faults.arm(:invocation_request_committed, :kill, notify: self())

    {pid, ref} = spawn_monitor(fn -> invoke(nurse, record_target(), %{"title" => title}, key) end)

    assert_receive {:fault_fired, :invocation_request_committed, ^pid}, 10_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 10_000

    assert [row] = rows(nurse.tenant, key)
    assert [job] = jobs(row.id)
    await_job(job.id, :success)

    assert [%{status: :succeeded}] = rows(nurse.tenant, key)
    assert effects(nurse.tenant, title) == 1
  end

  test "a fault after the enqueue rolls back the row and its job together", %{nurse: nurse} do
    unique = System.unique_integer([:positive])
    key = "handoff:#{unique}"

    Faults.arm(:invocation_request_enqueued, :raise)

    result =
      try do
        invoke(nurse, record_target(), %{"title" => "Never recorded #{unique}"}, key)
      rescue
        error -> {:raised, error}
      end

    refute match?({:ok, _}, result)
    assert rows(nurse.tenant, key) == []
    assert orphan_job_ids() == []
  end

  test "a ready row whose job was lost is picked up by the sweep", %{nurse: nurse} do
    pause_execution!()
    unique = System.unique_integer([:positive])
    key = "handoff:#{unique}"
    title = "Renew the clinic licence #{unique}"

    {:ok, row} = invoke(nurse, record_target(), %{"title" => title}, key)
    assert [lost] = jobs(row.id)
    :ok = Oban.cancel_job(lost.id)

    # Ready, with no job that will run it.
    assert [%{status: :ready}] = rows(nurse.tenant, key)
    refute Enum.any?(jobs(row.id), &(&1.state in ~w(available scheduled executing retryable)))

    # It is what the sweep selects.
    id = row.id

    assert [%{id: ^id}] =
             Invocation
             |> Ash.Query.filter(
               id == ^id and status == :ready and
                 (is_nil(next_attempt_at) or next_attempt_at <= now())
             )
             |> Ash.read!(oban(nurse.tenant))

    Oban.resume_queue(queue: :execution)
    sweep = Oban.insert!(ExecuteScheduler.new(%{}))
    await_job(sweep.id, :success)

    assert [_lost, picked_up] = jobs(row.id)
    assert picked_up.worker == inspect(ExecuteWorker)
    await_job(picked_up.id, :success)

    assert [%{status: :succeeded}] = rows(nurse.tenant, key)
    assert effects(nurse.tenant, title) == 1
  end
end
