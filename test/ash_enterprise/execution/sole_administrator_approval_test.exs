defmodule AshEnterprise.Execution.SoleAdministratorApprovalTest do
  @moduledoc """
  The sole-administrator rule (ADR 0055, amended 2026-11-01): an organization that opts
  in lets its only administrator approve their own four-eyes request that names the
  Administrator role, as an explicit act on the approval task, recorded as such, and
  only while they remain the only administrator and the opt-in stands.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  import AshEnterprise.Test.AssistantFixtures, only: [tenant!: 0, colleague!: 2]

  alias AshAgent.Invocation.Executor
  alias AshEnterprise.Accounts
  alias AshEnterprise.Accounts.Organization
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.{Approval, Invocation}
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security
  alias AshEnterprise.Test.Execution.NoteTaker

  @publish %{"approval" => "four_eyes", "approver_role" => "administrator"}
  @committee %{"approval" => "four_eyes", "approver_role" => "credentialing_committee"}

  setup do
    %{ctx: tenant!()}
  end

  defp opts(%{actor: actor, tenant: tenant}), do: [actor: actor, tenant: tenant]
  defp oban(tenant), do: [actor: SystemActor.oban(), tenant: tenant]

  defp allow!(ctx, allowed? \\ true) do
    Organization.set_sole_administrator_approval!(organization(ctx), allowed?, actor: ctx.actor)
  end

  defp organization(ctx), do: Ash.get!(Organization, ctx.tenant, authorize?: false)

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

  describe "with the opt-in off" do
    test "the only administrator cannot approve their own publish", %{ctx: ctx} do
      {draft, row} = requested!(ctx)

      refute Approval.sole_administrator?(ctx.tenant, ctx.user.id, row.effects)
      assert {:error, _not_a_candidate} = decide!(row, ctx)
      assert row.status == :awaiting_approval
      assert Execution.get_agent_version!(draft.id, opts(ctx)).status == :draft
    end
  end

  describe "with the opt-in on" do
    test "the only administrator approves their own publish, recorded as such", %{ctx: ctx} do
      allow!(ctx)
      {draft, row} = requested!(ctx)

      assert Approval.sole_administrator?(ctx.tenant, ctx.user.id, row.effects)
      assert {:ok, _} = decide!(row, ctx)

      ready = apply_decision!(ctx, row)
      assert %{status: :ready, approval_basis: :sole_administrator} = ready
      assert ready.approved_by_id == ctx.user.id

      assert {:ok, :succeeded} = Executor.execute(Invocation, row.id, oban(ctx.tenant))
      assert Execution.get_agent_version!(draft.id, opts(ctx)).status == :published

      done = Execution.get_invocation!(row.id, authorize?: false, tenant: ctx.tenant)
      assert done.approval_basis == :sole_administrator
    end

    test "with a second administrator, the requester is still excluded", %{ctx: ctx} do
      allow!(ctx)
      approver = colleague!(ctx, admin?: true)
      {_draft, row} = requested!(ctx)

      refute Approval.sole_administrator?(ctx.tenant, ctx.user.id, row.effects)
      assert {:error, _not_a_candidate} = decide!(row, ctx)

      assert {:ok, _} = decide!(row, approver)
      assert %{status: :ready, approval_basis: :four_eyes} = apply_decision!(ctx, row)
    end

    test "an administrator through a team is a second administrator", %{ctx: ctx} do
      allow!(ctx)
      colleague = colleague!(ctx, [])

      team =
        Accounts.Team
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Admins", team_type: :owner, owning_business_unit_id: ctx.business_unit.id},
          authorize?: false,
          tenant: ctx.tenant
        )
        |> Ash.create!()

      Accounts.TeamMembership
      |> Ash.Changeset.for_create(:create, %{team_id: team.id, user_id: colleague.user.id},
        authorize?: false,
        tenant: ctx.tenant
      )
      |> Ash.create!()

      assert Approval.sole_administrator?(ctx.tenant, ctx.user.id, @publish)

      Security.TeamRole
      |> Ash.Changeset.for_create(
        :assign,
        %{team_id: team.id, role_id: ctx.role.id, scoping_business_unit_id: ctx.business_unit.id},
        authorize?: false,
        tenant: ctx.tenant
      )
      |> Ash.create!()

      refute Approval.sole_administrator?(ctx.tenant, ctx.user.id, @publish)
    end

    test "a second administrator added before the decision is applied makes it stale", %{
      ctx: ctx
    } do
      allow!(ctx)
      {draft, row} = requested!(ctx)
      assert {:ok, _} = decide!(row, ctx)

      colleague!(ctx, admin?: true)

      assert %{status: :stale, error_code: "approved_by_requester", approval_basis: nil} =
               apply_decision!(ctx, row)

      assert Execution.get_agent_version!(draft.id, opts(ctx)).status == :draft
    end

    test "the opt-in turned off before the decision is applied makes it stale", %{ctx: ctx} do
      allow!(ctx)
      {_draft, row} = requested!(ctx)
      assert {:ok, _} = decide!(row, ctx)

      allow!(ctx, false)

      assert %{status: :stale, error_code: "approved_by_requester"} = apply_decision!(ctx, row)
    end

    test "a second administrator added after approval fails the claim", %{ctx: ctx} do
      allow!(ctx)
      {draft, row} = requested!(ctx)
      assert {:ok, _} = decide!(row, ctx)
      assert %{status: :ready} = apply_decision!(ctx, row)

      colleague!(ctx, admin?: true)

      Executor.execute(Invocation, row.id, oban(ctx.tenant))

      assert %{status: :stale, error_code: "approver_unauthorized"} =
               Execution.get_invocation!(row.id, authorize?: false, tenant: ctx.tenant)

      assert Execution.get_agent_version!(draft.id, opts(ctx)).status == :draft
    end
  end

  describe "other approver roles" do
    test "a credentialing committee's four eyes is never relaxed", %{ctx: ctx} do
      allow!(ctx)

      committee =
        Security.Role
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Credentialing committee", owning_business_unit_id: ctx.business_unit.id},
          authorize?: false,
          tenant: ctx.tenant
        )
        |> Ash.create!()

      Security.UserRole
      |> Ash.Changeset.for_create(
        :assign,
        %{
          user_id: ctx.user.id,
          role_id: committee.id,
          scoping_business_unit_id: ctx.business_unit.id
        },
        authorize?: false,
        tenant: ctx.tenant
      )
      |> Ash.create!()

      refute Approval.sole_administrator?(ctx.tenant, ctx.user.id, @committee)

      assert Approval.task_options("A.activate", @committee, ctx.tenant, ctx.user.id)[:excluding] ==
               ["subject.owner_id"]

      assert Approval.task_options("A.publish", @publish, ctx.tenant, ctx.user.id)[:excluding] ==
               []
    end
  end

  describe "setting the opt-in" do
    test "an administrator sets it for their own organization, and it is audited", %{ctx: ctx} do
      assert %{sole_administrator_approval: true} = allow!(ctx)

      assert [%{user_id: user_id}] =
               AshEnterprise.Audit.EventLog
               |> Ash.Query.filter(
                 resource == ^Organization and record_id == ^ctx.tenant and
                   action == :set_sole_administrator_approval
               )
               |> Ash.read!(authorize?: false)

      assert user_id == ctx.user.id
      assert %{sole_administrator_approval: false} = allow!(ctx, false)
    end

    test "a member without the Administrator role cannot", %{ctx: ctx} do
      member = colleague!(ctx, [])

      assert {:error, %Ash.Error.Forbidden{}} =
               Organization.set_sole_administrator_approval(organization(ctx), true,
                 actor: member.actor
               )

      refute organization(ctx).sole_administrator_approval
    end

    test "another tenant's administrator cannot, nor can a system actor", %{ctx: ctx} do
      other = tenant!()

      assert {:error, %Ash.Error.Forbidden{}} =
               Organization.set_sole_administrator_approval(organization(ctx), true,
                 actor: other.actor
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Organization.set_sole_administrator_approval(organization(ctx), true,
                 actor: SystemActor.seed()
               )

      refute organization(ctx).sole_administrator_approval
    end

    test "the general update does not set it", %{ctx: ctx} do
      assert {:error, %Ash.Error.Invalid{}} =
               organization(ctx)
               |> Ash.Changeset.for_update(:update, %{sole_administrator_approval: true},
                 actor: ctx.actor
               )
               |> Ash.update()
    end
  end
end
