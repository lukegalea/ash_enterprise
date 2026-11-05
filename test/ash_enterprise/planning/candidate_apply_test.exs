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

  test "a source that moved after the snapshot refuses the apply: rejected and stale, nothing written",
       ctx do
    %{w: w, candidate: candidate, tasks: [a, _]} = ctx
    approved = Planning.approve_planning_candidate!(candidate, %{}, w.aopts)
    Task.set_estimate_mine!(a.id, 90, w.aopts)

    assert {:error, _} = Planning.apply_planning_candidate(approved, %{}, w.aopts)

    reloaded = Planning.get_planning_candidate!(candidate.id, w.aopts)
    assert reloaded.freshness == :stale
    assert reloaded.disposition == :rejected

    for task <- Task.read!(w.aopts), do: assert(is_nil(task.scheduled_start_at))
  end

  test "a write-time refusal rolls every write back and settles identically", ctx do
    %{w: w, run: run, payload: payload} = ctx
    [first, second] = payload["ids"]["tasks"]

    # The first assignment is valid and is written; the second is refused mid-transaction.
    assignments = [
      %{"kind" => "task", "id" => first, "scheduled" => true, "start_slot" => 400},
      %{"kind" => "task", "id" => second, "scheduled" => true, "start_slot" => "x"}
    ]

    oban = [actor: AshEnterprise.Platform.SystemActor.oban(), tenant: w.admin.tenant]

    bad =
      Planning.propose_planning_candidate!(
        %{run_id: run.id, index: 7, assignments: Jason.encode!(assignments)},
        oban
      )
      |> Planning.record_planning_check!(%{check_status: :correct}, oban)
      |> Planning.approve_planning_candidate!(%{}, w.aopts)

    assert {:error, _} = Planning.apply_planning_candidate(bad, %{}, w.aopts)

    reloaded = Planning.get_planning_candidate!(bad.id, w.aopts)
    assert reloaded.freshness == :stale
    assert reloaded.disposition == :rejected

    for task <- Task.read!(w.aopts), do: assert(is_nil(task.scheduled_start_at))
  end

  test "the recheck reads each source row under a shared row lock" do
    query = AshEnterprise.Planning.Changes.ApplyCandidate.source_query(Task, Ecto.UUID.generate())
    assert query.lock == "FOR SHARE"
  end

  test "a target with no version precondition is excluded and counted, not drift" do
    alias AshEnterprise.Planning.Changes.ApplyCandidate
    alias AshOpenLineage.Snapshot
    alias AshOpenLineage.Snapshot.Input

    input = fn id, version ->
      %Input{
        key: id,
        role: :task,
        status: :value,
        source: %{resource: "AshEnterprise.Canonical.Task", id: id, version_number: version},
        content_hash: nil
      }
    end

    snapshot = %Snapshot{
      id: "s",
      purpose: :"planning.personal_week",
      effective_at: DateTime.utc_now(),
      knowledge_cutoff: DateTime.utc_now(),
      world: :operational,
      authority: %{tenant: nil, actor_id: nil, completeness: :authorized_subset},
      inputs: [input.("a", 3), input.("b", nil)],
      definitions: []
    }

    assignments = [
      %{"kind" => "task", "id" => "a", "scheduled" => true, "start_slot" => 1},
      %{"kind" => "task", "id" => "b", "scheduled" => true, "start_slot" => 2},
      %{"kind" => "meeting", "id" => "m", "attended" => true}
    ]

    assert {[%{"id" => "a"}], [%{"id" => "b"}]} = ApplyCandidate.partition(snapshot, assignments)
  end
end
