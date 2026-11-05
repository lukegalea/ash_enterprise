defmodule AshEnterprise.Planning.CandidateApplyTest do
  @moduledoc """
  `Candidate.apply` rechecks every snapshot source, then writes through the task self-service
  actions in one transaction as the approving person; drift refuses and marks stale.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Planning.TestKit

  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Planning
  alias AshEnterprise.Planning.{CheckPipeline, Lowering, SnapshotBuilder}

  setup do
    publish_requirements!()
    w = world!()
    a = task!(w, "write", 60)
    b = task!(w, "review", 30)
    {run, payload} = solved!(w)
    :ok = CheckPipeline.process(run)
    [candidate] = Planning.list_planning_candidates!(w.aopts)
    %{w: w, run: run, payload: payload, candidate: candidate, tasks: [a, b]}
  end

  test "an approved, current candidate schedules its tasks as the approver", ctx do
    %{w: w, candidate: candidate, payload: payload} = ctx
    assert candidate.check_status == :correct
    approved = Planning.approve_planning_candidate!(candidate, %{}, w.aopts)
    applied = Planning.apply_planning_candidate!(approved, %{}, w.aopts)
    assert applied.disposition == :applied
    assert applied.applied_by_actor_id == w.admin.actor.id

    {:ok, snapshot} = SnapshotBuilder.snapshot_from_payload(payload)

    for {id, slot} <- Enum.zip(payload["ids"]["tasks"], [400, 410]) do
      task = Task.read!(w.aopts) |> Enum.find(&(&1.id == id))
      assert task.scheduled_start_at == Lowering.slot_to_datetime(snapshot.effective_at, slot)
    end
  end

  test "a source that moved after the snapshot refuses the apply and marks the candidate stale",
       ctx do
    %{w: w, candidate: candidate, tasks: [a, _]} = ctx
    approved = Planning.approve_planning_candidate!(candidate, %{}, w.aopts)
    Task.set_estimate_mine!(a.id, 90, w.aopts)

    assert {:error, _} = Planning.apply_planning_candidate(approved, %{}, w.aopts)

    reloaded = Planning.get_planning_candidate!(candidate.id, w.aopts)
    assert reloaded.freshness == :stale
    assert reloaded.disposition == :approved

    for task <- Task.read!(w.aopts), do: assert(is_nil(task.scheduled_start_at))
  end
end
