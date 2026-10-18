defmodule AshEnterprise.Security.TaskCandidacyTest do
  @moduledoc """
  Candidacy grants read (ADR 0009, note of 2026-10-17): the tasks in a
  person's precomputed `ActorContext.task_ids` are readable by them, and
  nothing else is — phrased, as the conformance table is, as what must not
  happen.

  Every person here holds no grant on tasks at all, so whatever they read
  comes from `AshEnterprise.Security.Checks.TaskCandidacy`.

  SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3, actor: 1]

  alias AshEnterprise.Accounts.{Team, TeamMembership}
  alias AshEnterprise.Bpmn.{HumanTask, TaskCandidate}
  alias AshEnterprise.Security.{ActorContext, Checks}

  setup do
    admin = tenant!()
    %{admin: admin, alice: member!(admin, "Alice", []), bob: member!(admin, "Bob", [])}
  end

  defp task!(tenant, attrs \\ %{}) do
    HumanTask.create!(Map.merge(%{node_id: "Review", name: "Review"}, attrs),
      tenant: tenant,
      authorize?: false
    )
  end

  defp candidate!(task, type, id) do
    TaskCandidate.create!(%{task_id: task.id, principal_type: type, principal_id: id},
      tenant: task.organization_id,
      authorize?: false
    )
  end

  defp team!(admin, members) do
    team =
      Team
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Reviewers #{System.unique_integer([:positive])}",
          team_type: :access,
          owning_business_unit_id: admin.user.owning_business_unit_id
        },
        tenant: admin.tenant,
        authorize?: false
      )
      |> Ash.create!()

    for person <- members do
      TeamMembership
      |> Ash.Changeset.for_create(:create, %{user_id: person.user.id, team_id: team.id},
        tenant: admin.tenant,
        authorize?: false
      )
      |> Ash.create!()
    end

    team
  end

  # A new request: the context built after the rows exist.
  defp reads(person) do
    HumanTask
    |> Ash.read!(actor: actor(person.user), tenant: person.tenant)
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  test "a candidate with no task grant reads their task and no other", ctx do
    mine = task!(ctx.admin.tenant)
    theirs = task!(ctx.admin.tenant)
    candidate!(mine, :user, ctx.alice.user.id)
    candidate!(theirs, :user, ctx.bob.user.id)

    assert reads(ctx.alice) == [mine.id]
    assert reads(ctx.bob) == [theirs.id]
  end

  test "a team's candidacy reaches its members, and only them", ctx do
    team = team!(ctx.admin, [ctx.alice])
    task = task!(ctx.admin.tenant)
    candidate!(task, :team, team.id)

    assert reads(ctx.alice) == [task.id]
    assert reads(ctx.bob) == []
  end

  # Maker-checker is subtraction at candidate resolution; the requester's id
  # recorded on the task keeps a candidate team from readmitting them.
  test "an excluded requester in a candidate team reads nothing through candidacy", ctx do
    team = team!(ctx.admin, [ctx.alice, ctx.bob])
    task = task!(ctx.admin.tenant, %{excluded_principal_ids: [ctx.alice.user.id]})
    candidate!(task, :team, team.id)

    assert reads(ctx.alice) == []
    assert reads(ctx.bob) == [task.id]

    alice = actor(ctx.alice.user)

    assert {:error, %Ash.Error.Forbidden{}} =
             HumanTask
             |> Ash.ActionInput.for_action(:claim_task, %{record_id: task.id},
               actor: alice,
               tenant: ctx.admin.tenant
             )
             |> Ash.run_action()

    assert Ash.get!(HumanTask, task.id, authorize?: false, tenant: ctx.admin.tenant).status ==
             :open
  end

  test "a claimed task is readable by its holder, and a decided one by nobody new", ctx do
    task = task!(ctx.admin.tenant)
    candidate!(task, :user, ctx.alice.user.id)

    {:ok, claimed} = AshBpmn.claim_task(task, actor: ctx.alice.user, tenant: ctx.admin.tenant)
    assert reads(ctx.alice) == [task.id]

    {:ok, _done} =
      AshBpmn.complete_task(claimed,
        outcome: "approved",
        actor: ctx.alice.user,
        tenant: ctx.admin.tenant
      )

    # Decided, it leaves the live set: candidacy no longer reaches it.
    assert reads(ctx.alice) == []
  end

  test "candidacy reads only: it never authorizes a write to the task", ctx do
    task = task!(ctx.admin.tenant)
    candidate!(task, :user, ctx.alice.user.id)
    alice = actor(ctx.alice.user)

    refute Ash.can?({task, :attach_timers}, alice, tenant: ctx.admin.tenant)
    refute Ash.can?({task, :force_complete}, alice, tenant: ctx.admin.tenant)
  end

  test "the check reads the precomputed ids and nothing else" do
    context = %ActorContext{user_id: Ash.UUID.generate(), task_ids: []}
    read = %{action: %{type: :read, name: :read}, resource: HumanTask}

    # No live task: contributes nothing (no filter, no query).
    assert Checks.TaskCandidacy.filter(context, read, []) == false

    id = Ash.UUID.generate()
    filter = Checks.TaskCandidacy.filter(%{context | task_ids: [id]}, read, [])
    assert inspect(filter) =~ id

    act = %{action: %{type: :action, name: :claim_task}, resource: HumanTask}
    other = %{action: %{type: :action, name: :queue_digest}, resource: HumanTask}
    assert Checks.TaskCandidacy.filter(%{context | task_ids: [id]}, act, acts: [:claim_task])
    refute Checks.TaskCandidacy.filter(%{context | task_ids: [id]}, other, acts: [:claim_task])
  end
end
