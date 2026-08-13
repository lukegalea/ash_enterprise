defmodule AshEnterprise.AI.ProposalTest do
  @moduledoc """
  The headline agent flow, end to end:

      "assign the admin role to user XYZ"
        -> proposal (names resolved as the requester)
        -> authorization pre-check
        -> human approval
        -> execution as the human
        -> AuditEntry

  Deliberately exercised **without a model**. The interpretation step is the only
  part that needs one, and it is the only part that cannot change anything. Every
  safety property below -- who may propose, who may execute, what gets recorded --
  is ordinary Ash code and is tested as such.

  That separation is the point of the design, not a testing convenience: a flow
  whose security depends on model behaviour cannot be tested at all.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.AI.Proposal
  alias AshEnterprise.Security.ActorContext

  setup do
    seeded =
      AshEnterprise.Platform.Seeder.seed_tenant(
        unique_name: "agent-#{System.unique_integer([:positive])}"
      )

    tenant = seeded.organization.id
    admin = actor(seeded.user, tenant)
    target = user("target-#{System.unique_integer([:positive])}@example.com", seeded, tenant)

    %{seeded: seeded, tenant: tenant, admin: admin, target: target}
  end

  describe "building a proposal" do
    test "resolves a user and role by the names a human would use", ctx do
      assert {:ok, proposal} =
               Proposal.assign_role(ctx.admin, ctx.tenant, ctx.target.email, "Administrator")

      assert proposal.kind == :assign_role
      assert proposal.summary =~ "Administrator"
      assert proposal.summary =~ to_string(ctx.target.email)
      assert proposal.action == :assign
    end

    test "reports unknown names instead of inventing a target", ctx do
      assert {:error, message} =
               Proposal.assign_role(ctx.admin, ctx.tenant, "nobody@example.com", "Administrator")

      assert message =~ "No user found"
    end

    test "resolution runs as the requester, so it cannot see what they cannot", ctx do
      # A user holding no roles can see neither the target user nor the role, so
      # resolution fails at the first lookup. They get "not found" rather than a
      # proposal referencing records they have no business knowing exist -- the
      # same reasoning as Ash filtering reads rather than forbidding them.
      #
      # Note this is stronger than it looks: the admin CAN resolve both, with
      # the identical arguments, in the tests above. The difference is purely
      # the actor.
      stranger =
        actor(
          user(
            "stranger-#{System.unique_integer([:positive])}@example.com",
            ctx.seeded,
            ctx.tenant
          ),
          ctx.tenant
        )

      assert {:error, message} =
               Proposal.assign_role(stranger, ctx.tenant, ctx.target.email, "Administrator")

      assert message =~ "No user found" or message =~ "No role found"
    end
  end

  describe "authorization is checked before the human is asked" do
    test "an actor who could not perform the mutation is refused", ctx do
      stranger_user =
        user("nope-#{System.unique_integer([:positive])}@example.com", ctx.seeded, ctx.tenant)

      stranger = actor(stranger_user, ctx.tenant)

      # Build the proposal as the admin so resolution succeeds, then check it
      # against an actor who holds nothing.
      {:ok, proposal} =
        Proposal.assign_role(ctx.admin, ctx.tenant, ctx.target.email, "Administrator")

      assert {:error, message} = Proposal.authorize(proposal, stranger, ctx.tenant)
      assert message =~ "do not have permission"
    end

    test "the seeded administrator is permitted", ctx do
      {:ok, proposal} =
        Proposal.assign_role(ctx.admin, ctx.tenant, ctx.target.email, "Administrator")

      assert :ok = Proposal.authorize(proposal, ctx.admin, ctx.tenant)
    end
  end

  describe "execution" do
    test "a proposal changes nothing until it is executed", ctx do
      {:ok, _proposal} =
        Proposal.assign_role(ctx.admin, ctx.tenant, ctx.target.email, "Administrator")

      # The proposal exists. The assignment must not.
      assert role_assignments(ctx.target, ctx.tenant) == 0
    end

    test "approving performs the mutation", ctx do
      {:ok, proposal} =
        Proposal.assign_role(ctx.admin, ctx.tenant, ctx.target.email, "Administrator")

      assert {:ok, _} = Proposal.execute(proposal, ctx.admin, ctx.tenant)
      assert role_assignments(ctx.target, ctx.tenant) == 1
    end

    test "execution re-checks authorization rather than trusting the earlier check", ctx do
      {:ok, proposal} =
        Proposal.assign_role(ctx.admin, ctx.tenant, ctx.target.email, "Administrator")

      stranger =
        actor(
          user("late-#{System.unique_integer([:positive])}@example.com", ctx.seeded, ctx.tenant),
          ctx.tenant
        )

      # An actor's roles can change between a proposal being shown and approved.
      assert {:error, _} = Proposal.execute(proposal, stranger, ctx.tenant)
      assert role_assignments(ctx.target, ctx.tenant) == 0
    end

    test "the audit entry names the human who approved, not the agent", ctx do
      {:ok, proposal} =
        Proposal.assign_role(ctx.admin, ctx.tenant, ctx.target.email, "Administrator")

      before = audit_events_for(AshEnterprise.Security.UserRole)

      {:ok, _} = Proposal.execute(proposal, ctx.admin, ctx.tenant)

      events = audit_events_for(AshEnterprise.Security.UserRole)
      assert length(events) == before |> length() |> Kernel.+(1)

      event = List.last(events)

      # The action name, not a generic :create -- so the log says what happened.
      assert event.action == :assign

      # And the actor is the approving human. This is the attribution that
      # matters: the model proposed, but the person decided.
      assert event.user_id == ctx.admin.id
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp actor(user, tenant),
    do: ActorContext.attach(user, ActorContext.build(user, tenant: tenant))

  defp user(email, seeded, tenant) do
    AshEnterprise.Accounts.User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{email: email, password: "password1234", password_confirmation: "password1234"},
      authorize?: false
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(
      :assign_to_business_unit,
      %{owning_business_unit_id: seeded.business_unit.id},
      authorize?: false
    )
    |> Ash.update!()
    |> Map.put(:organization_id, tenant)
  end

  defp role_assignments(user, tenant) do
    AshEnterprise.Security.UserRole
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.read!(authorize?: false, tenant: tenant)
    |> length()
  end

  defp audit_events_for(resource) do
    AshEnterprise.Audit.EventLog
    |> Ash.Query.filter(resource == ^resource)
    |> Ash.Query.sort(occurred_at: :asc)
    |> Ash.read!(authorize?: false)
  end
end
