defmodule AshEnterprise.AgentSpike.S6StandaloneApprovalTest do
  @moduledoc """
  Spike S6: a standalone approval, end to end, through the host's existing
  doors. Nothing in the host requested a standalone approval before this.

  **Reading tested.**

    1. A request computes the approval's options at runtime (approver role,
       four-eyes exclusion, expiry) and delegates to
       `AshBpmn.Changes.RequireApproval` (`AshEnterprise.AgentSpike.RequestApproval`).
    2. A candidate reaches the instance-less task through `TaskCandidacy`;
       the excluded requester does not, even holding the approver role.
    3. The decision goes through the existing `HumanTask.approve` door.
    4. A trigger on a calculated `where` (approved task exists) applies the
       decision: it checks the decider is a person other than the owner and
       moves the row to ready. Nothing is applied by `on_complete`.
    5. A second request for the same subject and key, while one is pending,
       is refused and changes nothing.

  **Result: holds.** All five pass on `AshEnterprise.AgentSpike.Subject`
  (an existing table; no schema added). Findings for the real
  implementation: the expiry is a timer job on the task (`timer_job_ids`),
  not a column, so the subject keeps its own `approval_expires_at`; and the
  task records `decided_by_id` without a principal type, so "the decider is
  a person" is a lookup the applying trigger makes.

  Fallback had this failed (plan Risk 2): a host task path that does not go
  through `RequireApproval`.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3, actor: 1]

  require Ash.Query

  alias AshEnterprise.AgentSpike.{RequestApproval, Subject}
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security

  @role "Clinic lead"
  @declaration %{approver_role: @role, approval: :four_eyes, expires_in: [days: 3]}

  setup do
    admin = tenant!()
    approver = member!(admin, @role, [])
    requester = member!(admin, "Clinician", [])
    bystander = member!(admin, "Front desk", [])
    # The requester holds the approver role too, so only four-eyes keeps them out.
    grant_role!(requester, @role, admin.tenant)

    task =
      Task.capture!("Release the SYNTHETIC test results to the patient portal", %{},
        actor: requester.actor,
        tenant: admin.tenant
      )

    %{
      tenant: admin.tenant,
      requester: requester,
      approver: approver,
      bystander: bystander,
      row: Ash.get!(Subject, task.id, actor: SystemActor.oban(), tenant: admin.tenant)
    }
  end

  defp grant_role!(person, role_name, tenant) do
    role =
      Security.Role
      |> Ash.Query.filter(name == ^role_name)
      |> Ash.read_one!(authorize?: false, tenant: tenant)

    Security.UserRole
    |> Ash.Changeset.for_create(
      :assign,
      %{
        user_id: person.user.id,
        role_id: role.id,
        scoping_business_unit_id: person.user.owning_business_unit_id
      },
      actor: SystemActor.seed(),
      tenant: tenant
    )
    |> Ash.create!()
  end

  defp request(row, ctx) do
    row
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_context(%{approval_declaration: @declaration})
    |> Ash.Changeset.for_update(:request_approval, %{},
      actor: ctx.requester.actor,
      tenant: ctx.tenant,
      authorize?: false
    )
    |> Ash.update()
  end

  defp approval_task(row, tenant) do
    subject_type = to_string(Subject)
    key = RequestApproval.key()

    HumanTask
    |> Ash.Query.filter(
      subject_type == ^subject_type and subject_id == ^row.id and node_id == ^key
    )
    |> Ash.read_one!(authorize?: false, tenant: tenant)
  end

  # A fresh actor: candidacy is precomputed when the context is built.
  defp fresh(person), do: actor(person.user)

  defp approve(task, person, tenant) do
    HumanTask
    |> Ash.ActionInput.for_action(:approve, %{record_id: task.id},
      actor: fresh(person),
      tenant: tenant
    )
    |> Ash.run_action()
  end

  test "request, candidacy, decision through the door, application by the trigger", ctx do
    assert {:ok, %Subject{status: :proposed}} = request(ctx.row, ctx)

    task = approval_task(ctx.row, ctx.tenant)
    assert task.status == :open
    assert is_nil(task.instance_id)
    # Runtime-computed expiry: a timer job, not a column on the task.
    assert [_expire_job] = task.timer_job_ids
    # Four-eyes: the requester is excluded although they hold the approver role.
    assert ctx.requester.user.id in task.excluded_principal_ids

    # Candidacy through TaskCandidacy, for a task with no process instance.
    read_as = fn person ->
      Ash.get(HumanTask, task.id, actor: fresh(person), tenant: ctx.tenant)
    end

    assert {:ok, _} = read_as.(ctx.approver)
    assert {:error, _} = read_as.(ctx.requester)
    assert {:error, _} = read_as.(ctx.bystander)

    assert {:error, _} = approve(task, ctx.requester, ctx.tenant)
    assert {:ok, _message} = approve(task, ctx.approver, ctx.tenant)

    decided = approval_task(ctx.row, ctx.tenant)
    assert decided.status == :completed
    assert decided.outcome == "approved"
    assert decided.decided_by_id == ctx.approver.user.id

    # Nothing applied the decision yet: no on_complete, only the trigger.
    oban = [actor: SystemActor.oban(), tenant: ctx.tenant]
    assert Ash.get!(Subject, ctx.row.id, oban).status == :proposed

    assert %{success: success, failure: 0} =
             AshOban.Test.schedule_and_run_triggers({Subject, :apply_decision})

    assert success >= 1
    assert Ash.get!(Subject, ctx.row.id, oban).status == :open
  end

  test "a second pending request for the same subject and key is refused", ctx do
    assert {:ok, pending} = request(ctx.row, ctx)

    # Back to ready without deciding the task, so the action's own guard passes
    # and only the pending-approval check can refuse it.
    oban = [actor: SystemActor.oban(), tenant: ctx.tenant]

    reopened =
      pending
      |> Ash.Changeset.for_update(:set_plan, %{plan: :inbox}, oban)
      |> Ash.Changeset.force_change_attribute(:status, :open)
      |> Ash.update!()

    assert {:error, error} = request(reopened, ctx)
    assert Exception.message(error) =~ "already pending"

    # The refused request changed nothing and left one live task.
    assert Ash.get!(Subject, ctx.row.id, oban).status == :open

    subject_type = to_string(Subject)
    id = ctx.row.id

    live =
      HumanTask
      |> Ash.Query.filter(
        subject_type == ^subject_type and subject_id == ^id and status in [:open, :claimed]
      )
      |> Ash.read!(authorize?: false, tenant: ctx.tenant)

    assert [_one] = live
  end

  test "the trigger does not apply a rejection", ctx do
    assert {:ok, _} = request(ctx.row, ctx)
    task = approval_task(ctx.row, ctx.tenant)

    assert {:ok, _} =
             HumanTask
             |> Ash.ActionInput.for_action(:reject, %{record_id: task.id},
               actor: fresh(ctx.approver),
               tenant: ctx.tenant
             )
             |> Ash.run_action()

    AshOban.Test.schedule_and_run_triggers({Subject, :apply_decision})

    oban = [actor: SystemActor.oban(), tenant: ctx.tenant]
    assert Ash.get!(Subject, ctx.row.id, oban).status == :proposed
  end
end
