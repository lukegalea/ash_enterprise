defmodule AshEnterprise.Bpmn.RoleChangeReviewPackTest do
  @moduledoc """
  The `soc2_cc6_3` pack's recipe (SOC 2 CC6.3, role changes are authorized): when a role is
  assigned, an administrator other than the person who assigned it confirms or challenges
  the change.

  Installed, the pack is drafts and does nothing; it fires only once a person has published
  its process and its recipe. Published in one tenant it does nothing for another tenant's
  assignments. Fired, it opens one review, which the granter cannot complete because they
  are excluded from its candidates, and which another administrator completes. A repeat of
  an assignment already in force opens no second review.

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
end
