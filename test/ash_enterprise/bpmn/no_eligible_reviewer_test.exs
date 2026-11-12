defmodule AshEnterprise.Bpmn.NoEligibleReviewerTest do
  @moduledoc """
  A review whose candidates, minus its exclusions, leave nobody.

  Found on a real deployment: a tenant's only Administrator granted a role, the
  `soc2_cc6_3` review excluded the granter, and the task was written with no candidate, so
  nobody could ever act on it and nothing said so. Now `ash_bpmn` asks
  `AshEnterprise.Process.AssignmentResolver.no_eligible_candidate/2`, which falls back to the
  tenant's `Platform Operator` role; the engine subtracts the exclusions again; and
  `AshEnterprise.Bpmn.Changes.RecordUnassignableFinding` raises a `CC6.3` finding in the same
  transaction. The fallback never crosses tenants and never brings the granter or the grantee
  back in. SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  import AshEnterprise.Test.AssistantFixtures, only: [tenant!: 0, colleague!: 1, actor: 2]

  require Ash.Query

  alias AshEnterprise.Bpmn.{
    Definition,
    HumanTask,
    Instance,
    Subscription,
    TaskCandidate
  }

  alias AshEnterprise.Bpmn.Changes.RecordUnassignableFinding
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security.{Role, UserRole}

  @pack "soc2_cc6_3"
  @process "access.review_role_change"
  @recipe "soc2.cc6_3.role_assigned"

  # A tenant whose only Administrator is `admin`, a person with no role, a role to give
  # them, and the pack installed and published by the administrator.
  defp lone_admin_tenant! do
    admin = tenant!()
    newcomer = colleague!(admin)
    role = role!(admin.tenant, "Report Reader #{unique()}")

    {:ok, _} = Subscription.install_pack(@pack, actor: admin.actor, tenant: admin.tenant)

    %{admin: admin, newcomer: newcomer, role: role, tenant: admin.tenant}
  end

  defp unique, do: System.unique_integer([:positive])

  defp role!(tenant, name) do
    Role
    |> Ash.Changeset.for_create(:create, %{name: name}, actor: SystemActor.seed(), tenant: tenant)
    |> Ash.create!()
  end

  # Before the pack is published, so holding it opens no review of its own.
  defp make_operator!(ctx, person) do
    operator_role =
      Role
      |> Ash.Query.filter(name == "Platform Operator")
      |> Ash.read_one!(authorize?: false, tenant: ctx.tenant) ||
        role!(ctx.tenant, "Platform Operator")

    UserRole
    |> Ash.Changeset.for_create(:assign, %{user_id: person.user.id, role_id: operator_role.id},
      tenant: ctx.tenant,
      authorize?: false
    )
    |> Ash.create!()

    person
  end

  defp publish!(ctx) do
    opts = [actor: ctx.admin.actor, tenant: ctx.tenant]
    [process] = drafts(Definition, @process, ctx.tenant)
    Definition.publish!(process, opts)
    [recipe] = drafts(Subscription, @recipe, ctx.tenant)
    Subscription.publish!(recipe, opts)
  end

  defp drafts(resource, key, tenant) do
    resource
    |> Ash.Query.filter(key == ^key and status == :draft)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  # The administrator gives the newcomer the role: the event the recipe watches.
  defp assign!(ctx) do
    UserRole
    |> Ash.Changeset.for_create(
      :assign,
      %{user_id: ctx.newcomer.user.id, role_id: ctx.role.id},
      actor: ctx.admin.actor,
      tenant: ctx.tenant
    )
    |> Ash.create!()
  end

  defp sweep!(tenant) do
    inline = Application.get_env(:ash_bpmn, :oban_testing)
    Application.put_env(:ash_bpmn, :oban_testing, nil)

    try do
      AshBpmn.Triggers.SweepWorker.perform(%Oban.Job{args: %{"tenant" => tenant}})
    after
      Application.put_env(:ash_bpmn, :oban_testing, inline)
    end

    for job <- all_enqueued(worker: AshBpmn.Runtime.AdvanceWorker) do
      perform_job(AshBpmn.Runtime.AdvanceWorker, job.args)
    end
  end

  defp review!(tenant) do
    assert [task] =
             HumanTask
             |> Ash.Query.filter(status == :open)
             |> Ash.read!(authorize?: false, tenant: tenant)

    task
  end

  defp candidate_ids(task, tenant) do
    TaskCandidate
    |> Ash.Query.filter(task_id == ^task.id)
    |> Ash.read!(authorize?: false, tenant: tenant)
    |> Enum.map(& &1.principal_id)
  end

  defp findings(organization_id) do
    {:ok, findings} =
      AshCompliance.Domain.findings_for_organization(organization_id, authorize?: false)

    Enum.filter(findings, &(&1.subject_type == RecordUnassignableFinding.subject_type()))
  end

  # The actor as a request would build it now, after the task exists.
  defp now_actor(person, tenant), do: actor(person.user, tenant)

  defp decide(task, action, person, tenant) do
    HumanTask
    |> Ash.ActionInput.for_action(action, %{record_id: task.id},
      actor: now_actor(person, tenant),
      tenant: tenant
    )
    |> Ash.run_action()
  end

  defp refused?(result), do: match?({:error, %Ash.Error.Forbidden{}}, result)

  defp awaiting(person, tenant) do
    HumanTask
    |> Ash.Query.for_read(:awaiting_me, %{}, actor: now_actor(person, tenant), tenant: tenant)
    |> Ash.Query.load(:routing_label)
    |> Ash.read!()
  end

  test "with no fallback in the tenant, the review has nobody, and a high finding says so" do
    ctx = lone_admin_tenant!()
    publish!(ctx)

    assign!(ctx)
    sweep!(ctx.tenant)

    task = review!(ctx.tenant)
    assert candidate_ids(task, ctx.tenant) == []
    assert ctx.admin.user.id in task.excluded_principal_ids
    assert ctx.newcomer.user.id in task.excluded_principal_ids

    assert [finding] = findings(ctx.tenant)
    assert finding.control_id == "CC6.3"
    assert finding.subject_id == task.id
    assert finding.status == :unknown
    assert finding.severity == :high
    assert finding.gap == "no_eligible_candidate"
    assert finding.explanation =~ "nobody can act on it"
    assert is_nil(finding.resolved_at)

    for person <- [ctx.admin, ctx.newcomer], action <- [:approve, :reject] do
      assert refused?(decide(task, action, person, ctx.tenant))
    end

    assert review!(ctx.tenant).id == task.id
  end

  test "another tenant's operator is no fallback here, and the finding stays in its tenant" do
    elsewhere = lone_admin_tenant!()
    operator = make_operator!(elsewhere, colleague!(elsewhere.admin))

    ctx = lone_admin_tenant!()
    publish!(ctx)
    assign!(ctx)
    sweep!(ctx.tenant)

    task = review!(ctx.tenant)
    assert candidate_ids(task, ctx.tenant) == []
    refute operator.user.id in candidate_ids(task, ctx.tenant)

    for action <- [:approve, :reject] do
      assert {:error, _} =
               HumanTask
               |> Ash.ActionInput.for_action(action, %{record_id: task.id},
                 actor: now_actor(operator, elsewhere.tenant),
                 tenant: ctx.tenant
               )
               |> Ash.run_action()
    end

    assert awaiting(operator, elsewhere.tenant) == []
    assert [%{severity: :high}] = findings(ctx.tenant)
    assert findings(elsewhere.tenant) == []
  end

  test "the fallback never brings back the granter or the grantee" do
    ctx = lone_admin_tenant!()
    make_operator!(ctx, ctx.admin)
    make_operator!(ctx, ctx.newcomer)
    publish!(ctx)

    assign!(ctx)
    sweep!(ctx.tenant)

    task = review!(ctx.tenant)
    assert candidate_ids(task, ctx.tenant) == []
    assert [%{severity: :high}] = findings(ctx.tenant)

    for person <- [ctx.admin, ctx.newcomer], action <- [:approve, :reject] do
      assert refused?(decide(task, action, person, ctx.tenant))
    end

    assert awaiting(ctx.admin, ctx.tenant) == []
    assert awaiting(ctx.newcomer, ctx.tenant) == []
  end

  test "an operator who is neither gets the review, marked in their list, and completes it" do
    ctx = lone_admin_tenant!()
    operator = make_operator!(ctx, colleague!(ctx.admin))
    publish!(ctx)

    assign!(ctx)
    sweep!(ctx.tenant)

    task = review!(ctx.tenant)
    assert candidate_ids(task, ctx.tenant) == [operator.user.id]

    assert [finding] = findings(ctx.tenant)
    assert finding.control_id == "CC6.3"
    assert finding.subject_id == task.id
    assert finding.severity == :medium
    assert finding.explanation =~ "escalated to 1 fallback reviewer"

    # The excluded granter and grantee still cannot act.
    for person <- [ctx.admin, ctx.newcomer], action <- [:approve, :reject] do
      assert refused?(decide(task, action, person, ctx.tenant))
    end

    assert [listed] = awaiting(operator, ctx.tenant)
    assert listed.id == task.id
    assert listed.routing_label =~ "No eligible reviewer: escalated to the fallback (1)"

    assert {:ok, _} = decide(task, :approve, operator, ctx.tenant)

    assert %{status: :completed, outcome: "confirmed"} =
             Ash.get!(Instance, task.instance_id, authorize?: false, tenant: ctx.tenant)
  end
end
