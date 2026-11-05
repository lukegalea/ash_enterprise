defmodule AshEnterprise.AI.RoleRequestTest do
  @moduledoc """
  The admin chat's role flow, below the model call:

      "assign the admin role to user XYZ"
        -> a role request (names resolved as the requester)
        -> sent as them: `UserRole.request_assignment`, a governed invocation (ADR 0055)
        -> another administrator approves it (four eyes)
        -> it runs as the requester, through policies, into the audit log

  Exercised without a model: interpretation is the only part that needs one, and it
  cannot change anything. That four eyes holds once the request exists, and that the
  assignment then runs as the requester, is `AshEnterprise.Execution.GovernedTest`'s
  and the sole-administrator test's; here, that the chat's path reaches it and
  changes nothing on its own.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.AI.{Intent, Interpreter}
  alias AshEnterprise.Execution.Actions.ConfirmInvocation
  alias AshEnterprise.Security.{ActorContext, UserRole}

  setup do
    seeded =
      AshEnterprise.Platform.Seeder.seed_tenant(
        unique_name: "agent-#{System.unique_integer([:positive])}"
      )

    tenant = seeded.organization.id
    admin = actor(seeded.user, tenant)
    target = user("target-#{System.unique_integer([:positive])}@example.test", seeded, tenant)

    %{seeded: seeded, tenant: tenant, admin: admin, target: target}
  end

  defp intent(email, role),
    do: %Intent{kind: :assign_role, user_email: email, role_name: role}

  describe "the request" do
    test "names a user and a role as a person would, resolved as the requester", ctx do
      assert {:ok, {:role_request, request}} =
               Interpreter.plan(
                 intent(to_string(ctx.target.email), "Administrator"),
                 "...",
                 ctx.admin,
                 ctx.tenant
               )

      assert request.user_id == ctx.target.id
      assert request.user == to_string(ctx.target.email)
      assert request.role == "Administrator"
    end

    test "an unknown name is reported, not invented", ctx do
      assert {:error, message} =
               Interpreter.plan(
                 intent("nobody@example.test", "Administrator"),
                 "...",
                 ctx.admin,
                 ctx.tenant
               )

      assert message =~ "No user found"
    end

    test "a requester who cannot read the user or the role cannot ask about them", ctx do
      stranger =
        actor(
          user(
            "stranger-#{System.unique_integer([:positive])}@example.test",
            ctx.seeded,
            ctx.tenant
          ),
          ctx.tenant
        )

      assert {:error, message} =
               Interpreter.plan(
                 intent(to_string(ctx.target.email), "Administrator"),
                 "...",
                 stranger,
                 ctx.tenant
               )

      assert message =~ "No user found" or message =~ "No role found"
    end
  end

  describe "sending it" do
    test "asks for the assignment and changes nothing; the requester cannot approve it",
         ctx do
      {:ok, {:role_request, request}} =
        Interpreter.plan(
          intent(to_string(ctx.target.email), "Administrator"),
          "...",
          ctx.admin,
          ctx.tenant
        )

      assert {:ok, %{"status" => "awaiting_approval", "invocation_id" => id} = sent} =
               UserRole.request_assignment(request.user_id, request.role_id,
                 actor: ctx.admin,
                 tenant: ctx.tenant
               )

      assert sent["approval_url"] =~ "/app/r/approvals/"
      assert role_assignments(ctx.target, ctx.tenant) == 0

      # Four eyes: their own confirmation leaves it waiting for someone else.
      row = AshEnterprise.Execution.get_invocation!(id, authorize?: false, tenant: ctx.tenant)

      assert {:ok, %{status: :awaiting_approval}} =
               ConfirmInvocation.confirm(row, ctx.admin, ctx.tenant)

      assert role_assignments(ctx.target, ctx.tenant) == 0
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
    UserRole
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.read!(authorize?: false, tenant: tenant)
    |> length()
  end
end
