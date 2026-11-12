defmodule AshEnterprise.Bpmn.RoleChangeReviewPackTest do
  @moduledoc """
  The `soc2_cc6_3` pack's recipes (SOC 2 CC6.3, role changes are authorized): when a role is
  assigned, or an assignment is extended to last longer, an administrator who is neither the
  person who made the change nor the person it is about confirms or challenges it.

  Installed, the pack is drafts and does nothing; it fires only once a person has published
  its process and its recipes. Published in one tenant it does nothing for another tenant's
  assignments. Fired, it opens one review, which the granter cannot complete because they
  are excluded from its candidates, nor the grantee, and which another administrator
  completes. A repeat of an assignment already in force opens no second review. Extending an
  assignment opens a review; shortening it opens none, and revoking one has no recipe (it
  narrows access, and the audit chain records it).

  What this proves is that a change opened a review and that someone other than the granter
  recorded an outcome. It does not prove the review was good, or that CC6.3 is met.
  SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  import AshEnterprise.Test.AssistantFixtures, only: [tenant!: 0, colleague!: 1, colleague!: 2]

  require Ash.Query

  alias AshEnterprise.Bpmn.{
    Definition,
    Dispatch,
    HumanTask,
    Instance,
    Subscription,
    TaskCandidate
  }

  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security.{Role, UserRole}

  @pack "soc2_cc6_3"
  @process "access.review_role_change"
  @recipe "soc2.cc6_3.role_assigned"
  @extended "soc2.cc6_3.role_extended"

  # A tenant with the pack installed by its administrator, a second administrator, a person
  # with no role, and a role to give them.
  defp installed_tenant! do
    admin = tenant!()
    reviewer = colleague!(admin, admin?: true)
    newcomer = colleague!(admin)

    role =
      Role
      |> Ash.Changeset.for_create(:create, %{name: "Report Reader #{unique()}"},
        actor: SystemActor.seed(),
        tenant: admin.tenant
      )
      |> Ash.create!()

    {:ok, _} = Subscription.install_pack(@pack, actor: admin.actor, tenant: admin.tenant)

    %{admin: admin, reviewer: reviewer, newcomer: newcomer, role: role, tenant: admin.tenant}
  end

  defp unique, do: System.unique_integer([:positive])

  # A person publishes the pack's process, then its recipe: the only way it goes live.
  defp publish!(ctx, person) do
    opts = [actor: person.actor, tenant: ctx.tenant]

    [process] = drafts(Definition, @process, ctx.tenant)
    Definition.publish!(process, opts)

    for key <- [@recipe, @extended] do
      [recipe] = drafts(Subscription, key, ctx.tenant)
      Subscription.publish!(recipe, opts)
    end
  end

  defp drafts(resource, key, tenant) do
    resource
    |> Ash.Query.filter(key == ^key and status == :draft)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  # The administrator gives the newcomer the role: the event the recipe watches.
  defp assign!(ctx, grantee \\ nil, extra \\ %{}) do
    grantee = grantee || ctx.newcomer

    UserRole
    |> Ash.Changeset.for_create(
      :assign,
      Map.merge(%{user_id: grantee.user.id, role_id: ctx.role.id}, extra),
      actor: ctx.admin.actor,
      tenant: ctx.tenant
    )
    |> Ash.create!()
  end

  # The administrator moves the assignment's end.
  defp set_valid_until!(ctx, assignment, valid_until) do
    assignment
    |> Ash.Changeset.for_update(:set_valid_until, %{valid_until: valid_until},
      actor: ctx.admin.actor,
      tenant: ctx.tenant
    )
    |> Ash.update!()
  end

  defp days(n), do: DateTime.add(DateTime.utc_now(), n * 86_400, :second)

  defp candidate_ids(task, tenant) do
    TaskCandidate
    |> Ash.Query.filter(task_id == ^task.id)
    |> Ash.read!(authorize?: false, tenant: tenant)
    |> Enum.map(& &1.principal_id)
  end

  # The person as a request would build them now, after the task exists.
  defp now(person, tenant),
    do: %{person | actor: AshEnterprise.Test.AssistantFixtures.actor(person.user, tenant)}

  # The sweep as production runs it: the first advance is a job that runs once the instance
  # and its dispatch have committed together, and later advances run here.
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

  defp all(resource, tenant), do: Ash.read!(resource, authorize?: false, tenant: tenant)

  defp reviews(tenant) do
    HumanTask
    |> Ash.Query.filter(status == :open)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  defp decide(task, action, person, tenant) do
    HumanTask
    |> Ash.ActionInput.for_action(action, %{record_id: task.id},
      actor: person.actor,
      tenant: tenant
    )
    |> Ash.run_action()
  end

  test "nothing fires before a person publishes" do
    ctx = installed_tenant!()

    assign!(ctx)
    sweep!(ctx.tenant)

    assert all(Dispatch, ctx.tenant) == []
    assert all(Instance, ctx.tenant) == []
    assert reviews(ctx.tenant) == []
  end

  test "a pack installed and published in one tenant does nothing for another's assignments" do
    published = installed_tenant!()
    publish!(published, published.admin)

    other = installed_tenant!()
    assign!(other)

    sweep!(other.tenant)
    sweep!(published.tenant)

    for ctx <- [published, other] do
      assert all(Dispatch, ctx.tenant) == []
      assert all(Instance, ctx.tenant) == []
      assert reviews(ctx.tenant) == []
    end
  end

  test "a role assignment opens a review the granter cannot complete" do
    ctx = installed_tenant!()
    publish!(ctx, ctx.admin)

    assignment = assign!(ctx)
    sweep!(ctx.tenant)

    assert [%{status: :started, instance_id: instance_id}] = all(Dispatch, ctx.tenant)
    instance = Ash.get!(Instance, instance_id, authorize?: false, tenant: ctx.tenant)
    assert instance.started_by_id == ctx.admin.user.id

    assert [task] = reviews(ctx.tenant)
    assert ctx.admin.user.id in task.excluded_principal_ids

    candidates =
      TaskCandidate
      |> Ash.Query.filter(task_id == ^task.id)
      |> Ash.read!(authorize?: false, tenant: ctx.tenant)
      |> Enum.map(& &1.principal_id)

    refute ctx.admin.user.id in candidates
    refute ctx.newcomer.user.id in candidates
    assert ctx.reviewer.user.id in candidates

    # The granter, an administrator who can read every task, cannot confirm or challenge
    # their own change, and the review stays open.
    granter = %{
      ctx.admin
      | actor: AshEnterprise.Test.AssistantFixtures.actor(ctx.admin.user, ctx.tenant)
    }

    for action <- [:approve, :reject] do
      assert {:error, %Ash.Error.Forbidden{}} = decide(task, action, granter, ctx.tenant)
    end

    assert [%{id: open_id}] = reviews(ctx.tenant)
    assert open_id == task.id

    # Another administrator records the outcome.
    assert {:ok, _} = decide(task, :approve, ctx.reviewer, ctx.tenant)
    assert reviews(ctx.tenant) == []

    assert %{status: :completed, outcome: "confirmed"} =
             Ash.get!(Instance, instance_id, authorize?: false, tenant: ctx.tenant)

    assert %{subject_id: subject_id} = instance
    assert subject_id == assignment.id
  end

  test "a repeat of an assignment in force opens one review" do
    ctx = installed_tenant!()
    publish!(ctx, ctx.admin)

    first = assign!(ctx)
    assert assign!(ctx).id == first.id
    sweep!(ctx.tenant)

    assert [_one] = all(Dispatch, ctx.tenant)
    assert [_one] = reviews(ctx.tenant)
  end

  test "the person receiving the role cannot approve their own change" do
    ctx = installed_tenant!()
    # An administrator already, so without the grantee's exclusion they would be a candidate.
    grantee = colleague!(ctx.admin, admin?: true)
    publish!(ctx, ctx.admin)

    assign!(ctx, grantee)
    sweep!(ctx.tenant)

    assert [task] = reviews(ctx.tenant)
    assert grantee.user.id in task.excluded_principal_ids

    candidates = candidate_ids(task, ctx.tenant)
    refute grantee.user.id in candidates
    refute ctx.admin.user.id in candidates
    assert ctx.reviewer.user.id in candidates

    for action <- [:approve, :reject] do
      assert {:error, %Ash.Error.Forbidden{}} =
               decide(task, action, now(grantee, ctx.tenant), ctx.tenant)
    end

    assert [%{id: open_id}] = reviews(ctx.tenant)
    assert open_id == task.id

    assert {:ok, _} = decide(task, :approve, now(ctx.reviewer, ctx.tenant), ctx.tenant)
    assert reviews(ctx.tenant) == []
  end

  test "shortening an assignment, or clearing an end it never had, opens no review" do
    ctx = installed_tenant!()
    ending = assign!(ctx, nil, %{valid_until: days(30)})
    open_ended = assign!(ctx, colleague!(ctx.admin))
    publish!(ctx, ctx.admin)

    set_valid_until!(ctx, ending, days(10))
    set_valid_until!(ctx, open_ended, nil)
    sweep!(ctx.tenant)

    assert all(Instance, ctx.tenant) == []
    assert reviews(ctx.tenant) == []
  end

  test "an extension in another tenant opens nothing in either" do
    published = installed_tenant!()
    publish!(published, published.admin)

    other = installed_tenant!()
    assignment = assign!(other, nil, %{valid_until: days(10)})
    set_valid_until!(other, assignment, days(90))

    sweep!(other.tenant)
    sweep!(published.tenant)

    for ctx <- [published, other] do
      assert all(Instance, ctx.tenant) == []
      assert reviews(ctx.tenant) == []
    end
  end

  test "extending an assignment opens a review the extender and the grantee cannot complete" do
    ctx = installed_tenant!()
    assignment = assign!(ctx, nil, %{valid_until: days(10)})
    publish!(ctx, ctx.admin)

    set_valid_until!(ctx, assignment, days(90))
    sweep!(ctx.tenant)

    assert [%{status: :started, instance_id: instance_id}] = all(Dispatch, ctx.tenant)
    instance = Ash.get!(Instance, instance_id, authorize?: false, tenant: ctx.tenant)
    assert instance.subject_id == assignment.id
    assert instance.started_by_id == ctx.admin.user.id

    assert [task] = reviews(ctx.tenant)
    assert ctx.admin.user.id in task.excluded_principal_ids
    assert ctx.newcomer.user.id in task.excluded_principal_ids
    assert ctx.reviewer.user.id in candidate_ids(task, ctx.tenant)

    for person <- [ctx.admin, ctx.newcomer], action <- [:approve, :reject] do
      assert {:error, %Ash.Error.Forbidden{}} =
               decide(task, action, now(person, ctx.tenant), ctx.tenant)
    end

    assert {:ok, _} = decide(task, :reject, now(ctx.reviewer, ctx.tenant), ctx.tenant)

    assert %{status: :completed, outcome: "challenged"} =
             Ash.get!(Instance, instance_id, authorize?: false, tenant: ctx.tenant)
  end

  test "clearing an assignment's end makes it open-ended, which is reviewed as an extension" do
    ctx = installed_tenant!()
    assignment = assign!(ctx, nil, %{valid_until: days(10)})
    publish!(ctx, ctx.admin)

    set_valid_until!(ctx, assignment, nil)
    sweep!(ctx.tenant)

    assert [task] = reviews(ctx.tenant)
    assert ctx.newcomer.user.id in task.excluded_principal_ids
  end
end
