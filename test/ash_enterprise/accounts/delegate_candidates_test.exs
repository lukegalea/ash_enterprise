defmodule AshEnterprise.Accounts.DelegateCandidatesTest do
  @moduledoc """
  `User.delegate_candidates` — whom the holder of a task may hand it to, the
  task board's Delegate picker: exactly the people `AshBpmn.delegate_task/2`
  would accept, for the task's holder only.

  Every person here holds no grant on users or tasks, so what they read
  comes from `AshEnterprise.Security.Checks.TaskDelegates` (and their task
  from `TaskCandidacy`).

  SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3, actor: 1]

  alias AshEnterprise.Accounts.{Team, TeamMembership, User}
  alias AshEnterprise.Bpmn.{HumanTask, TaskCandidate}
  alias AshEnterprise.Security.{ActorContext, Checks}

  setup do
    admin = tenant!()

    %{
      admin: admin,
      alice: member!(admin, "Alice", []),
      bob: member!(admin, "Bob", []),
      carol: member!(admin, "Carol", []),
      dan: member!(admin, "Dan", [])
    }
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

  defp claim!(task, person) do
    {:ok, claimed} = AshBpmn.claim_task(task, actor: person.user, tenant: person.tenant)
    claimed
  end

  # A new request: the context built after the claim.
  defp delegates(person, task) do
    User
    |> Ash.Query.for_read(:delegate_candidates, %{task_id: task.id},
      actor: actor(person.user),
      tenant: person.tenant
    )
    |> Ash.read!()
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp ids(people), do: people |> Enum.map(& &1.user.id) |> Enum.sort()

  test "the holder reads the task's other candidates: named, and through a team", ctx do
    team = team!(ctx.admin, [ctx.carol])
    task = task!(ctx.admin.tenant)
    candidate!(task, :user, ctx.alice.user.id)
    candidate!(task, :user, ctx.bob.user.id)
    candidate!(task, :team, team.id)
    claim!(task, ctx.alice)

    # Not Alice herself, and not Dan, who is no candidate.
    assert delegates(ctx.alice, task) == ids([ctx.bob, ctx.carol])
  end

  # Maker-checker: the task records whom resolution subtracted, by their own
  # id or a team's, and a candidate team does not readmit them.
  test "an excluded person is not offered, by their own id or one of their teams", ctx do
    team = team!(ctx.admin, [ctx.bob, ctx.carol, ctx.dan])
    excluded_team = team!(ctx.admin, [ctx.dan])

    task =
      task!(ctx.admin.tenant, %{excluded_principal_ids: [ctx.bob.user.id, excluded_team.id]})

    candidate!(task, :user, ctx.alice.user.id)
    candidate!(task, :team, team.id)
    claim!(task, ctx.alice)

    assert delegates(ctx.alice, task) == ids([ctx.carol])
  end

  test "nobody is offered to a candidate who does not hold the task", ctx do
    task = task!(ctx.admin.tenant)
    candidate!(task, :user, ctx.alice.user.id)
    candidate!(task, :user, ctx.bob.user.id)

    # Open: a candidate, not yet the holder.
    assert delegates(ctx.alice, task) == []

    claim!(task, ctx.alice)
    assert delegates(ctx.bob, task) == []
    assert delegates(ctx.dan, task) == []
  end

  test "the grant reaches the delegate read for a live task, and nothing else" do
    id = Ash.UUID.generate()
    context = %ActorContext{user_id: Ash.UUID.generate(), task_ids: [id]}
    opts = [reads: [:delegate_candidates]]

    read = fn action, task_id ->
      %{
        action: %{type: :read, name: action},
        query: Ash.Query.for_read(User, action, %{task_id: task_id}, authorize?: false)
      }
    end

    assert Checks.TaskDelegates.filter(context, read.(:delegate_candidates, id), opts)

    refute Checks.TaskDelegates.filter(
             context,
             read.(:delegate_candidates, Ash.UUID.generate()),
             opts
           )

    refute Checks.TaskDelegates.filter(
             %{context | task_ids: []},
             read.(:delegate_candidates, id),
             opts
           )

    other = %{action: %{type: :read, name: :read}, query: Ash.Query.new(User)}
    refute Checks.TaskDelegates.filter(context, other, opts)
  end
end
