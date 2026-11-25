defmodule AshEnterprise.Process.EscalationTest do
  @moduledoc """
  The two host halves of a task timer that reaches people (`ash_bpmn` DESIGN.md §11.6,
  §11.7): whom `AshEnterprise.Process.AssignmentResolver.escalate/2` adds, and whom
  `AshEnterprise.Process.TaskNotices` tells, called directly. The process end to end is in
  `AshEnterprise.Process.AccessRequestDemoTest`. SYNTHETIC data only; mail goes to
  `Swoosh.Adapters.Test`.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.AssistantFixtures, only: [tenant!: 0, colleague!: 1]
  import Swoosh.TestAssertions

  alias AshBpmn.Notice
  alias AshEnterprise.Accounts.{Team, TeamMembership, User}
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Process.{AssignmentResolver, TaskNotice, TaskNotices}
  alias AshEnterprise.Process.Senders.SendTaskNotice
  alias AshEnterprise.Security.{Role, UserRole}
  alias AshEnterprise.Test.Process.FlakyMailer

  setup do
    ctx = tenant!()
    # Registering the fixtures' people sends their confirmation mail; none of it is ours.
    flush_mail()
    ctx
  end

  describe "escalate/2" do
    test "adds the managers of an unclaimed task's user candidates", ctx do
      manager = person!(ctx)
      reviewer = person!(ctx, manager: manager)

      assert {:ok, [%{type: :user, id: id}]} =
               AssignmentResolver.escalate(open_task(), escalation(ctx, [reviewer]))

      assert id == manager.id
    end

    test "on a claimed task, adds the holder's manager and nobody else's", ctx do
      holder_manager = person!(ctx)
      other_manager = person!(ctx)
      holder = person!(ctx, manager: holder_manager)
      other = person!(ctx, manager: other_manager)

      task = %{open_task() | status: :claimed, assignee_type: :user, assignee_id: holder.id}

      assert {:ok, [%{id: id}]} =
               AssignmentResolver.escalate(task, escalation(ctx, [holder, other]))

      assert id == holder_manager.id
    end

    test "never adds an excluded manager, and falls back to the operators instead", ctx do
      requester = person!(ctx)
      reviewer = person!(ctx, manager: requester)
      operator = operator!(ctx)

      assert {:ok, [%{id: id}]} =
               AssignmentResolver.escalate(
                 open_task([requester.id]),
                 escalation(ctx, [reviewer], [requester.id])
               )

      assert id == operator.id
      refute id == requester.id
    end

    test "with no manager and nobody in the fallback, reaches nobody", ctx do
      reviewer = person!(ctx)

      assert {:ok, []} = AssignmentResolver.escalate(open_task(), escalation(ctx, [reviewer]))
    end

    test "never returns a manager whose home is another organization", ctx do
      elsewhere = tenant!()
      foreign_manager = person!(elsewhere)
      reviewer = person!(ctx, manager: foreign_manager)

      assert {:ok, []} = AssignmentResolver.escalate(open_task(), escalation(ctx, [reviewer]))

      operator = operator!(ctx)

      assert {:ok, [%{id: id}]} =
               AssignmentResolver.escalate(open_task(), escalation(ctx, [reviewer]))

      assert id == operator.id
    end

    test "an inactive manager is no answer", ctx do
      manager = person!(ctx)
      reviewer = person!(ctx, manager: manager)
      deactivate!(manager)

      assert {:ok, []} = AssignmentResolver.escalate(open_task(), escalation(ctx, [reviewer]))
    end

    test "with no tenant anywhere, refuses rather than guessing" do
      assert {:error, :no_tenant} =
               AssignmentResolver.escalate(open_task(), %{candidates: [], exclusions: []})
    end
  end

  describe "TaskNotices.deliver/2" do
    test "tells each recipient once, in the app and by mail at their own address", ctx do
      reviewer = person!(ctx)
      added = person!(ctx)
      notice = notice(ctx, [user(reviewer), user(added)], kind: :escalated, added: [user(added)])

      assert :ok = TaskNotices.deliver(notice, %{tenant: ctx.tenant})

      for person <- [reviewer, added] do
        assert_email_sent(
          to: to_string(person.email),
          subject: SendTaskNotice.subject(:escalated)
        )
      end

      rows = notices(ctx)
      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.key == notice.key and &1.kind == :escalated))
      assert Enum.all?(rows, &(&1.owner_id == &1.user_id and &1.mailed_at))

      # The engine asks again with the same key: no second row, no second message.
      assert :ok = TaskNotices.deliver(notice, %{tenant: ctx.tenant})
      assert length(notices(ctx)) == 2
      refute_email_sent()
    end

    test "names no task, record or person in the message", ctx do
      reviewer = person!(ctx)
      notice = notice(ctx, [user(reviewer)])

      assert :ok = TaskNotices.deliver(notice, %{tenant: ctx.tenant})

      assert_email_sent(fn email ->
        refute email.text_body =~ notice.task.id
        refute email.text_body =~ notice.task.name
        assert email.text_body =~ "/app/tasks"
      end)
    end

    test "a failed message is retried under the same key: one row and one message", ctx do
      reviewer = person!(ctx)
      notice = notice(ctx, [user(reviewer)])

      start_supervised!({FlakyMailer, failures: 1})
      FlakyMailer.install()

      assert {:error, {:not_mailed, 1}} = TaskNotices.deliver(notice, %{tenant: ctx.tenant})
      refute_email_sent()
      assert [%{mailed_at: nil}] = notices(ctx)

      assert :ok = TaskNotices.deliver(notice, %{tenant: ctx.tenant})
      assert_email_sent(to: to_string(reviewer.email))
      assert [%{mailed_at: %DateTime{}}] = notices(ctx)

      assert :ok = TaskNotices.deliver(notice, %{tenant: ctx.tenant})
      refute_email_sent()
    end

    test "one address that always fails does not silence the people after it", ctx do
      first = person!(ctx)
      second = person!(ctx)
      notice = notice(ctx, [user(first), user(second)])

      start_supervised!({FlakyMailer, failing_addresses: [first.email]})
      FlakyMailer.install()

      # Retried for the one it missed, and everyone else is told on the first attempt.
      assert {:error, {:not_mailed, 1}} = TaskNotices.deliver(notice, %{tenant: ctx.tenant})
      assert_email_sent(to: to_string(second.email))
      assert Enum.sort(Enum.map(notices(ctx), & &1.user_id)) == Enum.sort([first.id, second.id])

      # The last attempt names who was not reached, and mails nobody twice.
      assert {:ok, %{not_reached: [{missed, :not_mailed}]}} =
               TaskNotices.deliver(notice, %{tenant: ctx.tenant, final_attempt?: true})

      assert missed == user(first)
      refute_email_sent()
    end

    test "a team whose member cannot be mailed is named as not reached on the last attempt",
         ctx do
      reachable = person!(ctx)
      unreachable = person!(ctx)
      team = team!(ctx, [reachable, unreachable])
      notice = notice(ctx, [%{type: :team, id: team.id}])

      start_supervised!({FlakyMailer, failing_addresses: [unreachable.email]})
      FlakyMailer.install()

      assert {:ok, %{not_reached: [{%{type: :team, id: team_id}, {:members_not_mailed, 1}}]}} =
               TaskNotices.deliver(notice, %{tenant: ctx.tenant, final_attempt?: true})

      assert team_id == team.id
      assert_email_sent(to: to_string(reachable.email))
    end

    test "an escalation of a claimed task says who can act, and does not say it is theirs",
         ctx do
      holder = person!(ctx)
      added = person!(ctx)

      notice =
        notice(ctx, [user(holder), user(added)],
          kind: :escalated,
          added: [user(added)],
          holder: user(holder)
        )

      assert :ok = TaskNotices.deliver(notice, %{tenant: ctx.tenant})

      assert_email_sent(fn email ->
        assert email.to == [{"", to_string(holder.email)}] or
                 email.to == [{"", to_string(added.email)}]

        refute email.text_body =~ "passed to you"
        assert email.text_body =~ "delegate"
      end)
    end

    test "an escalation of an open task says the person was added to those who can act", ctx do
      added = person!(ctx)
      notice = notice(ctx, [user(added)], kind: :escalated, added: [user(added)])

      assert :ok = TaskNotices.deliver(notice, %{tenant: ctx.tenant})

      assert_email_sent(fn email ->
        refute email.text_body =~ "passed to you"
        assert email.text_body =~ "added"
      end)
    end

    test "expands a team to its members and never tells an excluded one", ctx do
      requester = person!(ctx)
      member = person!(ctx)
      team = team!(ctx, [requester, member])

      notice =
        notice(ctx, [%{type: :team, id: team.id}], excluded: [requester.id])

      assert :ok = TaskNotices.deliver(notice, %{tenant: ctx.tenant})

      assert_email_sent(to: to_string(member.email))
      refute_email_sent()
      assert [%{user_id: user_id}] = notices(ctx)
      assert user_id == member.id
    end

    test "an excluded recipient is not told and not named as missed", ctx do
      requester = person!(ctx)
      reviewer = person!(ctx)

      notice =
        notice(ctx, [user(requester), user(reviewer)], excluded: [requester.id])

      assert :ok = TaskNotices.deliver(notice, %{tenant: ctx.tenant})
      assert_email_sent(to: to_string(reviewer.email))
      refute_email_sent()
    end

    test "never tells someone whose home is another organization", ctx do
      elsewhere = tenant!()
      foreign = person!(elsewhere)
      reviewer = person!(ctx)

      # Told, but named as not reached: the record must not say they were.
      assert {:ok, %{not_reached: [{not_told, :not_an_active_member}]}} =
               TaskNotices.deliver(notice(ctx, [user(foreign), user(reviewer)]), %{
                 tenant: ctx.tenant
               })

      assert not_told == user(foreign)
      assert_email_sent(to: to_string(reviewer.email))
      refute_email_sent()
    end

    test "a notice that reaches nobody is a final failure, never a delivery", ctx do
      requester = person!(ctx)

      assert {:error, {:final, :nobody_to_tell}} =
               TaskNotices.deliver(notice(ctx, []), %{tenant: ctx.tenant})

      assert {:error, {:final, :nobody_to_tell}} =
               TaskNotices.deliver(notice(ctx, [user(requester)], excluded: [requester.id]), %{
                 tenant: ctx.tenant
               })

      refute_email_sent()
      assert notices(ctx) == []
    end

    test "no tenant is refused", ctx do
      reviewer = person!(ctx)
      notice = %{notice(ctx, [user(reviewer)]) | tenant: nil}

      assert {:error, :no_tenant} = TaskNotices.deliver(notice, %{})
      refute_email_sent()
    end

    test "a person reads their own notices and nobody else's, and writes none", ctx do
      reviewer = person!(ctx)
      other = person!(ctx)

      assert :ok =
               TaskNotices.deliver(notice(ctx, [user(reviewer), user(other)]), %{
                 tenant: ctx.tenant
               })

      reviewer_actor = AshEnterprise.Test.AssistantFixtures.actor(reviewer, ctx.tenant)

      assert [%{user_id: id}] =
               TaskNotice
               |> Ash.Query.for_read(:read, %{}, actor: reviewer_actor, tenant: ctx.tenant)
               |> Ash.read!()

      assert id == reviewer.id

      # The tenant's administrator holds every grant, and still writes none.
      assert {:error, %Ash.Error.Forbidden{}} =
               TaskNotice
               |> Ash.Changeset.for_create(
                 :record,
                 %{key: "k", user_id: reviewer.id, task_id: Ecto.UUID.generate(), kind: :remind},
                 actor: ctx.actor,
                 tenant: ctx.tenant
               )
               |> Ash.create()
    end
  end

  # --- fixtures ------------------------------------------------------------------------

  defp person!(ctx, opts \\ []) do
    %{user: user} = colleague!(ctx)
    flush_mail()

    case Keyword.get(opts, :manager) do
      nil ->
        user

      manager ->
        user
        |> Ash.Changeset.for_update(:assign_manager, %{manager_id: manager.id}, authorize?: false)
        |> Ash.update!()
    end
  end

  defp deactivate!(user) do
    {1, _} =
      AshEnterprise.Repo.update_all(
        Ecto.Query.from(u in "users", where: u.id == type(^user.id, Ecto.UUID)),
        set: [lifecycle_status: "inactive"]
      )
  end

  defp operator!(ctx) do
    person = person!(ctx)

    role =
      Role
      |> Ash.Changeset.for_create(:create, %{name: "Platform Operator"},
        actor: SystemActor.seed(),
        tenant: ctx.tenant
      )
      |> Ash.create!()

    UserRole
    |> Ash.Changeset.for_create(:assign, %{user_id: person.id, role_id: role.id},
      tenant: ctx.tenant,
      authorize?: false
    )
    |> Ash.create!()

    person
  end

  defp team!(ctx, members) do
    team =
      Team
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Reviewers #{System.unique_integer([:positive])}"},
        actor: SystemActor.seed(),
        tenant: ctx.tenant
      )
      |> Ash.create!()

    for member <- members do
      TeamMembership.create!(%{team_id: team.id, user_id: member.id},
        actor: SystemActor.seed(),
        tenant: ctx.tenant
      )
    end

    team
  end

  defp open_task(excluded \\ []) do
    %{
      id: Ecto.UUID.generate(),
      status: :open,
      assignee_type: nil,
      assignee_id: nil,
      excluded_principal_ids: excluded
    }
  end

  defp escalation(ctx, candidates, excluded \\ []) do
    %{tenant: ctx.tenant, candidates: Enum.map(candidates, &user/1), exclusions: excluded}
  end

  defp notice(ctx, recipients, opts \\ []) do
    task = %{
      id: Ecto.UUID.generate(),
      name: "Synthetic review #{System.unique_integer([:positive])}",
      excluded_principal_ids: Keyword.get(opts, :excluded, [])
    }

    %Notice{
      key: "#{task.id}/Review/0/1",
      kind: Keyword.get(opts, :kind, :remind),
      task: task,
      recipients: recipients,
      added: Keyword.get(opts, :added, []),
      holder: Keyword.get(opts, :holder),
      tenant: ctx.tenant
    }
  end

  defp user(%User{id: id}), do: %{type: :user, id: id}

  defp notices(ctx) do
    TaskNotice
    |> Ash.Query.for_read(:read)
    |> Ash.read!(actor: SystemActor.process(), tenant: ctx.tenant)
  end

  defp flush_mail do
    receive do
      {:email, _email} -> flush_mail()
    after
      0 -> :ok
    end
  end
end
