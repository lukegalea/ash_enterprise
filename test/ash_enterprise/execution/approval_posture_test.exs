defmodule AshEnterprise.Execution.ApprovalPostureTest do
  @moduledoc """
  Approval postures (ADR 0055, amended 2026-11-12): the tenant's posture
  (`AshAgent.Approval.Posture`, carried by `Organization` and answered through
  `AshEnterprise.Execution.Authority`) decides which person approves a four-eyes
  request; it never lets anyone but a person decide, and a target declared at the
  floor keeps four eyes under every posture.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  import AshEnterprise.Test.AssistantFixtures, only: [tenant!: 0, colleague!: 2]

  alias AshEnterprise.Test.AssistantFixtures

  alias AshAgent.Approval.PostureChangeRefused
  alias AshAgent.Invocation.Executor
  alias AshEnterprise.Accounts
  alias AshEnterprise.Accounts.Organization
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.{Approval, Authority, Invocation}
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Security
  alias AshEnterprise.Test.Execution.NoteTaker

  setup do
    %{ctx: tenant!()}
  end

  defp opts(%{actor: actor, tenant: tenant}), do: [actor: actor, tenant: tenant]
  defp oban(tenant), do: [actor: SystemActor.oban(), tenant: tenant]

  defp organization(ctx), do: Ash.get!(Organization, ctx.tenant, authorize?: false)

  # Set as `by` (a person of the tenant, or the operator), in the organization's
  # tenant, as every caller of the action does.
  defp set_posture(ctx, posture, by, ends_at \\ nil, tenant \\ nil) do
    organization(ctx)
    |> Ash.Changeset.for_update(
      :set_approval_posture,
      %{approval_posture: posture, approval_posture_ends_at: ends_at},
      actor: by.actor,
      tenant: tenant || ctx.tenant
    )
    |> Ash.update()
  end

  defp set_posture!(ctx, posture, ends_at \\ nil) do
    {:ok, organization} = set_posture(ctx, posture, ctx, ends_at)
    organization
  end

  defp in_days(days), do: DateTime.add(DateTime.utc_now(), days, :day)

  # Asked for by `ctx`'s administrator: the invocation row waiting for approval.
  defp requested!(ctx) do
    draft = Execution.register_agent_from_code!(NoteTaker, opts(ctx))
    %{"invocation_id" => id} = Execution.request_agent_publish!(draft.id, opts(ctx))
    {draft, Execution.get_invocation!(id, authorize?: false, tenant: ctx.tenant)}
  end

  defp decide!(row, person, action \\ :approve) do
    task = Ash.load!(row, :approval_task, authorize?: false).approval_task

    HumanTask
    |> Ash.ActionInput.for_action(action, %{record_id: task.id},
      actor: person.actor,
      tenant: person.tenant
    )
    |> Ash.run_action()
  end

  defp apply_decision!(ctx, row), do: Execution.apply_invocation_decision!(row, oban(ctx.tenant))

  # The actor is built again after the grant: an actor carries the grants it was
  # built with.
  defp operator! do
    staff = tenant!()
    Seeder.grant_platform_operator(staff.user)
    %{staff | actor: AssistantFixtures.actor(staff.user, staff.tenant)}
  end

  # A request as `request` writes it, for the rule alone: the declaration of
  # `resource`'s `action` as the fragment snapshots it, made by `principal`.
  defp request_row(ctx, resource, action, principal) do
    effect = AshAgent.Effects.Info.effect(resource, action)

    %Invocation{
      target: "#{inspect(resource)}.#{action}",
      effects: AshAgent.Effects.Effect.to_map(effect),
      approval_mode: effect.approval,
      executing_principal: principal,
      owner_id: ctx.user.id,
      organization_id: ctx.tenant
    }
  end

  defp person(ctx), do: %{type: :person, id: ctx.user.id}

  defp automation(ctx),
    do: %{type: :automation, id: "intake", on_behalf_of: ctx.user.id, agent: "assistant"}

  describe ":standard, the default" do
    test "the only administrator cannot approve their own publish", %{ctx: ctx} do
      assert organization(ctx).approval_posture == :standard
      {draft, row} = requested!(ctx)

      assert {:error, _not_a_candidate} = decide!(row, ctx)
      assert Execution.get_agent_version!(draft.id, opts(ctx)).status == :draft
    end

    test "another administrator approves, on four eyes", %{ctx: ctx} do
      approver = colleague!(ctx, admin?: true)
      {_draft, row} = requested!(ctx)

      assert {:error, _not_a_candidate} = decide!(row, ctx)
      assert {:ok, _} = decide!(row, approver)
      assert %{status: :ready, approval_basis: :four_eyes} = apply_decision!(ctx, row)
    end
  end

  describe ":small_team" do
    test "a lone administrator publishes an agent, approving it themselves", %{ctx: ctx} do
      set_posture!(ctx, :small_team)
      {draft, row} = requested!(ctx)

      assert {:ok, _} = decide!(row, ctx)

      ready = apply_decision!(ctx, row)
      assert %{status: :ready, approval_basis: :small_team} = ready
      assert ready.approved_by_id == ctx.user.id

      assert {:ok, :succeeded} = Executor.execute(Invocation, row.id, oban(ctx.tenant))
      assert Execution.get_agent_version!(draft.id, opts(ctx)).status == :published

      done = Execution.get_invocation!(row.id, authorize?: false, tenant: ctx.tenant)
      assert done.approval_basis == :small_team
    end

    test "with a second administrator, either may approve: the requester's own is small_team",
         %{ctx: ctx} do
      set_posture!(ctx, :small_team)
      other = colleague!(ctx, admin?: true)

      {_draft, mine} = requested!(ctx)
      assert {:ok, _} = decide!(mine, ctx)
      assert %{status: :ready, approval_basis: :small_team} = apply_decision!(ctx, mine)

      {_draft, theirs} = requested!(ctx)
      assert {:ok, _} = decide!(theirs, other)
      assert %{status: :ready, approval_basis: :four_eyes} = apply_decision!(ctx, theirs)
    end

    test "raised to :standard before the decision is applied, a self-approval is stale",
         %{ctx: ctx} do
      set_posture!(ctx, :small_team)
      {draft, row} = requested!(ctx)
      assert {:ok, _} = decide!(row, ctx)

      set_posture!(ctx, :standard)

      assert %{status: :stale, error_code: "approved_by_requester", approval_basis: nil} =
               apply_decision!(ctx, row)

      assert Execution.get_agent_version!(draft.id, opts(ctx)).status == :draft
    end

    # The claim asks the rule again (`AshAgent.Invocation.Approval`): the
    # approver is the requester, whom four eyes now excludes.
    test "raised to :standard after approval, the claim fails", %{ctx: ctx} do
      set_posture!(ctx, :small_team)
      {draft, row} = requested!(ctx)
      assert {:ok, _} = decide!(row, ctx)
      assert %{status: :ready} = apply_decision!(ctx, row)

      set_posture!(ctx, :standard)
      Executor.execute(Invocation, row.id, oban(ctx.tenant))

      assert %{status: :stale, error_code: "approved_by_requester"} =
               Execution.get_invocation!(row.id, authorize?: false, tenant: ctx.tenant)

      assert Execution.get_agent_version!(draft.id, opts(ctx)).status == :draft
    end

    test "a target declared at the floor keeps four eyes", %{ctx: ctx} do
      set_posture!(ctx, :small_team)

      floored = request_row(ctx, Organization, :set_approval_posture, person(ctx))
      assert %{exclude_requester?: true, basis: :four_eyes} = Approval.rule(floored)
      assert Approval.task_options(floored)[:excluding] == ["subject.owner_id"]

      publish = request_row(ctx, Execution.AgentVersion, :apply_publish, person(ctx))
      assert %{exclude_requester?: false} = Approval.rule(publish)
      assert Approval.task_options(publish)[:excluding] == []
    end

    test "another tenant's posture has no effect", %{ctx: ctx} do
      other = tenant!()
      set_posture!(other, :small_team)

      {_draft, row} = requested!(ctx)
      assert {:error, _not_a_candidate} = decide!(row, ctx)
    end
  end

  describe ":implementation" do
    test "the requester confirms their own publish until the end date", %{ctx: ctx} do
      set_posture!(ctx, :implementation, in_days(30))
      {draft, row} = requested!(ctx)

      assert {:ok, _} = decide!(row, ctx)
      assert %{status: :ready, approval_basis: :implementation} = apply_decision!(ctx, row)

      assert {:ok, :succeeded} = Executor.execute(Invocation, row.id, oban(ctx.tenant))
      assert Execution.get_agent_version!(draft.id, opts(ctx)).status == :published
    end

    test "needs an end date, at most 120 days out", %{ctx: ctx} do
      assert {:error, %Ash.Error.Invalid{}} = set_posture(ctx, :implementation, ctx)
      assert {:error, %Ash.Error.Invalid{}} = set_posture(ctx, :implementation, ctx, in_days(121))
      assert organization(ctx).approval_posture == :standard
    end

    test "a member without the grant still cannot act", %{ctx: ctx} do
      set_posture!(ctx, :implementation, in_days(30))
      member = colleague!(ctx, [])
      draft = Execution.register_agent_from_code!(NoteTaker, opts(ctx))

      assert {:error, %Ash.Error.Forbidden{}} =
               Execution.request_agent_publish(draft.id, opts(member))

      assert Execution.get_agent_version!(draft.id, opts(ctx)).status == :draft
    end
  end

  describe "agents and automation principals" do
    test "never approve, under any posture", %{ctx: ctx} do
      for {posture, ends_at} <- [standard: nil, small_team: nil, implementation: in_days(30)] do
        Ash.Seed.update!(organization(ctx), %{
          approval_posture: posture,
          approval_posture_ends_at: ends_at
        })

        row = request_row(ctx, Execution.AgentVersion, :apply_publish, automation(ctx))

        assert %{exclude_requester?: true} = Approval.rule(row),
               "the person an automation acts for approved its request under #{posture}"
      end
    end
  end

  describe "who may set the posture" do
    test "lowering is refused for one of two administrators", %{ctx: ctx} do
      colleague!(ctx, admin?: true)

      assert {:error, %Ash.Error.Invalid{errors: errors}} = set_posture(ctx, :small_team, ctx)
      assert Enum.any?(errors, &match?(%PostureChangeRefused{reason: :lowering}, &1))
      assert organization(ctx).approval_posture == :standard
    end

    test "a true sole administrator may lower it, and it is audited", %{ctx: ctx} do
      assert %{approval_posture: :small_team} = set_posture!(ctx, :small_team)

      assert [%{user_id: user_id}] =
               AshEnterprise.Audit.EventLog
               |> Ash.Query.filter(
                 resource == ^Organization and record_id == ^ctx.tenant and
                   action == :set_approval_posture
               )
               |> Ash.read!(authorize?: false)

      assert user_id == ctx.user.id
    end

    test "the platform operator may lower it, in a tenant not their own", %{ctx: ctx} do
      colleague!(ctx, admin?: true)
      operator = operator!()

      assert Authority.operator?(operator.actor)
      assert {:ok, %{approval_posture: :small_team}} = set_posture(ctx, :small_team, operator)
    end

    test "either of two administrators may raise it", %{ctx: ctx} do
      set_posture!(ctx, :small_team)
      other = colleague!(ctx, admin?: true)

      assert {:ok, %{approval_posture: :standard}} = set_posture(ctx, :standard, other)
    end

    # Revoking a role, deactivating a person and leaving a team are each one
    # person's act: an administrator removed that way still counts, so the one
    # who removed them is not the sole administrator.
    test "an administrator who revoked another's role is not the sole administrator",
         %{ctx: ctx} do
      other = colleague!(ctx, admin?: true)

      Security.UserRole
      |> Ash.Query.filter(user_id == ^other.user.id)
      |> Ash.read_one!(opts(ctx))
      |> Security.UserRole.destroy!(opts(ctx))

      assert {:error, %Ash.Error.Invalid{}} = set_posture(ctx, :small_team, ctx)
    end

    test "an administrator who deactivated another is not the sole administrator",
         %{ctx: ctx} do
      ctx |> colleague!(admin?: true) |> AshEnterprise.Test.DailyFixtures.deactivate!()

      assert {:error, %Ash.Error.Invalid{}} = set_posture(ctx, :small_team, ctx)
    end

    test "an administrator through a team, even one taken off it, counts", %{ctx: ctx} do
      colleague = colleague!(ctx, [])
      team = admin_team!(ctx)

      membership =
        Accounts.TeamMembership
        |> Ash.Changeset.for_create(:create, %{team_id: team.id, user_id: colleague.user.id},
          authorize?: false,
          tenant: ctx.tenant
        )
        |> Ash.create!()

      assert colleague.user.id in Authority.holders(ctx.tenant, :administrator)

      Accounts.TeamMembership.destroy!(membership, opts(ctx))

      assert colleague.user.id in Authority.holders(ctx.tenant, :administrator)
      assert {:error, %Ash.Error.Invalid{}} = set_posture(ctx, :small_team, ctx)
    end

    # The rules find the role by its name: renaming the role both hold and creating
    # a new "Administrator" for oneself would set the second aside without revoking
    # anything, so the Administrator role keeps its name.
    test "renaming the Administrator role is refused", %{ctx: ctx} do
      colleague!(ctx, admin?: true)

      assert {:error, %Ash.Error.Invalid{errors: [%{field: :name}]}} =
               ctx.role
               |> Ash.Changeset.for_update(:update, %{name: "Former administrators"}, opts(ctx))
               |> Ash.update()
    end

    # The posture rule is asked before the policies, so it answers these first.
    test "a member without the Administrator role cannot", %{ctx: ctx} do
      member = colleague!(ctx, [])

      assert {:error, error} = set_posture(ctx, :small_team, member)
      assert refused?(error)

      set_posture!(ctx, :small_team)
      assert {:error, error} = set_posture(ctx, :standard, member)
      assert refused?(error)

      assert organization(ctx).approval_posture == :small_team
    end

    test "another tenant's administrator cannot, nor can a system actor", %{ctx: ctx} do
      other = tenant!()

      assert {:error, error} = set_posture(ctx, :small_team, other)
      assert refused?(error)

      assert {:error, error} = set_posture(ctx, :small_team, %{actor: SystemActor.seed()})
      assert refused?(error)

      assert organization(ctx).approval_posture == :standard
    end

    # Asked in their own tenant, another organization's sole administrator
    # satisfies the posture rule; the policy keeps them to their own row.
    test "another tenant's sole administrator, asking in their own tenant, is forbidden",
         %{ctx: ctx} do
      other = tenant!()

      assert {:error, %Ash.Error.Forbidden{}} =
               set_posture(ctx, :small_team, other, nil, other.tenant)

      assert organization(ctx).approval_posture == :standard
    end

    test "the general update does not set it", %{ctx: ctx} do
      assert {:error, %Ash.Error.Invalid{}} =
               organization(ctx)
               |> Ash.Changeset.for_update(:update, %{approval_posture: :small_team},
                 actor: ctx.actor
               )
               |> Ash.update()
    end
  end

  defp refused?(%Ash.Error.Forbidden{}), do: true

  defp refused?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &match?(%PostureChangeRefused{}, &1))

  defp refused?(_error), do: false

  defp admin_team!(ctx) do
    team =
      Accounts.Team
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Admins", team_type: :owner, owning_business_unit_id: ctx.business_unit.id},
        authorize?: false,
        tenant: ctx.tenant
      )
      |> Ash.create!()

    Security.TeamRole
    |> Ash.Changeset.for_create(
      :assign,
      %{team_id: team.id, role_id: ctx.role.id, scoping_business_unit_id: ctx.business_unit.id},
      authorize?: false,
      tenant: ctx.tenant
    )
    |> Ash.create!()

    team
  end
end
