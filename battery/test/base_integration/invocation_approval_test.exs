defmodule Battery.Integration.InvocationApprovalTest do
  @moduledoc """
  Scenario 5 — governed invocation ↔ process approval.

  The approval seam: an ash_agent invocation whose target declares four-eyes approval
  waits on a standalone ash_bpmn `HumanTask`, opened in the request's own transaction
  through `AshBpmn.Changes.RequireApproval` (candidates from the declared approver
  role, the requester excluded). A person decides the task through the engine
  (`AshBpmn.complete_task/2`, never `on_complete`), and the invocation's
  `apply_decision` reads the decision off the task. The fragment applies it only while
  the approval still binds the request: the digest of its RFC 9396
  `authorization_details`, recomputed from the row, the target as declared now and the
  subject as it stands now.

  Asserted: the task's candidacy and exclusion; the digest-bound approval and the run
  it allows; a subject changed while the approval was pending, and after it was
  given, leaves the row stale and the subject untouched; a rejection is applied as
  such.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias Battery.Bpmn.HumanTask
  alias Battery.Execution.{Invocation, Member, Referral, RequestApproval}

  @escalate "Battery.Execution.Referral.escalate"

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Battery.Repo, sandbox: false)

    for table <- ~w(battery_invocations battery_referrals battery_members bpmn_task_candidates
                    bpmn_human_tasks bpmn_process_events) do
      Battery.Repo.query!("DELETE FROM " <> table)
    end

    # The requester holds the approver role too: only four eyes keeps them out.
    requester = Ash.create!(Member, %{name: "Dana (nurse)", role: "clinic_lead"})
    lead = Ash.create!(Member, %{name: "Sam (clinic lead)", role: "clinic_lead"})
    porter = Ash.create!(Member, %{name: "Lee (porter)", role: "porter"})
    referral = Ash.create!(Referral, %{patient: "SYNTHETIC patient #{unique()}"})

    %{requester: requester, lead: lead, porter: porter, referral: referral}
  end

  defp unique, do: System.unique_integer([:positive])

  defp request!(ctx) do
    Ash.ActionInput.for_action(
      Invocation,
      :invoke,
      %{target: @escalate, args: %{"id" => ctx.referral.id}, key: "escalate:#{unique()}"},
      actor: ctx.requester
    )
    |> Ash.run_action!()
  end

  defp approval_task(row) do
    key = RequestApproval.key()
    id = row.id

    HumanTask
    |> Ash.Query.filter(subject_id == ^id and node_id == ^key)
    |> Ash.Query.load(:candidates)
    |> Ash.read_one!(authorize?: false)
  end

  defp decide(row, person, outcome),
    do: AshBpmn.complete_task(approval_task(row), outcome: outcome, actor: person)

  defp apply_decision(row) do
    row
    |> Ash.Changeset.for_update(:apply_decision, %{})
    |> Ash.update()
  end

  defp execute(row) do
    Ash.ActionInput.for_action(Invocation, :execute, %{primary_key: %{"id" => row.id}})
    |> Ash.run_action!()
  end

  defp amend!(referral) do
    referral = Ash.get!(Referral, referral.id)

    referral
    |> Ash.Changeset.for_update(:amend, %{patient: referral.patient <> " (amended)"})
    |> Ash.update!()
  end

  defp current(row), do: Ash.get!(Invocation, row.id)

  test "a four-eyes approval through a process task, bound to the request, lets it run once",
       ctx do
    row = request!(ctx)
    assert {row.status, row.approval_mode} == {:awaiting_approval, :four_eyes}

    # The task is the engine's, opened in the request's transaction, with no process.
    task = approval_task(row)
    assert {task.status, task.instance_id} == {:open, nil}
    assert Enum.map(task.candidates, & &1.principal_id) == [ctx.lead.id]
    assert ctx.requester.id in task.excluded_principal_ids

    # What the approval binds.
    assert [%{"type" => "urn:ash-agent:action:" <> @escalate, "identifier" => id} = details] =
             row.authorization_details

    assert id == ctx.referral.id

    assert details["preconditions"] == [
             %{"resource" => inspect(Referral), "id" => ctx.referral.id, "version_number" => 1}
           ]

    assert row.approval_digest == AshAgent.Digest.sha256_hex(row.authorization_details)

    # Nobody but a candidate decides it; nothing decided means nothing to apply.
    assert {:error, %ArgumentError{}} = decide(row, ctx.requester, :approved)
    assert {:error, %ArgumentError{}} = decide(row, ctx.porter, :approved)
    assert {:error, _} = apply_decision(row)
    assert current(row).status == :awaiting_approval

    assert {:ok, _} = decide(row, ctx.lead, :approved)
    assert {:ok, ready} = apply_decision(current(row))
    assert {ready.status, ready.approved_by_id} == {:ready, ctx.lead.id}

    assert execute(ready) == :succeeded
    assert Ash.get!(Referral, ctx.referral.id).urgent?
    assert execute(ready) == :skipped
  end

  test "the subject changed while the approval was pending: stale, never ready", ctx do
    row = request!(ctx)
    amend!(ctx.referral)
    assert {:ok, _} = decide(row, ctx.lead, :approved)

    assert {:ok, stale} = apply_decision(current(row))
    assert {stale.status, stale.error_code} == {:stale, "subject_changed"}
    refute Ash.get!(Referral, ctx.referral.id).urgent?
  end

  test "the subject changed after the approval: the claim finds it stale and nothing runs", ctx do
    row = request!(ctx)
    assert {:ok, _} = decide(row, ctx.lead, :approved)
    assert {:ok, %{status: :ready} = ready} = apply_decision(current(row))
    amend!(ctx.referral)

    assert execute(ready) == :stale
    assert {current(row).status, current(row).error_code} == {:stale, "subject_changed"}
    refute Ash.get!(Referral, ctx.referral.id).urgent?
  end

  test "a rejection is applied as a rejection", ctx do
    row = request!(ctx)
    assert {:ok, _} = decide(row, ctx.lead, :rejected)

    assert {:ok, rejected} = apply_decision(current(row))
    assert {rejected.status, rejected.failure_class} == {:rejected, :rejected}
  end
end
