defmodule AshEnterprise.Security.TenantResolutionTest do
  @moduledoc """
  That a signed-in user resolves to a tenant.

  `User` is `tenant?: false` — a user is scoped by the business unit that owns
  them rather than carrying `organization_id` directly. So every attempt to read
  the tenant off the user struct yields `nil`, and the request-scoped plug did
  exactly that (`ActorContext.build(user, tenant: Map.get(user, :organization_id))`),
  meaning **no request ever had a tenant set**.

  Nothing raised, because `global? true` on the multitenancy block accepts a nil
  tenant by design — it is what lets genuinely cross-tenant work run. The two
  consequences were therefore silent:

    * **reads spanned every tenant**, which the plug's own moduledoc names as
      "the worst possible failure mode for a multi-tenant system";
    * **creates inserted a null discriminator**, surfacing only where a
      not-null constraint happened to catch it — the agent console's role
      assignment, which failed at the database with the confirmation already
      approved.

  The suite did not catch it because its fixtures stamp `organization_id` onto
  the user struct by hand (`Map.put(:organization_id, org)`), which no production
  code path does. These tests deliberately use a user exactly as registration
  leaves it.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Accounts.BusinessUnit
  alias AshEnterprise.Security.ActorContext

  setup do
    org = Ash.UUID.generate()

    business_unit =
      BusinessUnit
      |> Ash.Changeset.for_create(:create, %{name: "Root"}, authorize?: false, tenant: org)
      |> Ash.create!()

    %{org: org, business_unit: business_unit, user: register(business_unit)}
  end

  test "a user carries no tenant attribute of its own", %{user: user} do
    # The premise of the bug. If this ever becomes false, the workaround the plug
    # used would start working and this whole file stops being about anything.
    refute Map.has_key?(user, :organization_id)
  end

  test "the tenant resolves through the user's business unit", %{user: user, org: org} do
    assert ActorContext.tenant(user) == org
  end

  test "the resolved context carries the tenant", %{user: user, org: org} do
    assert %ActorContext{organization_id: ^org} = ActorContext.build(user)
  end

  test "a user in no business unit resolves to no tenant rather than raising" do
    # Registration leaves a user unassigned until `assign_to_business_unit`, and
    # that user still signs in. Nil is the right answer here; the point is that
    # asking is safe.
    user =
      AshEnterprise.Accounts.User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "unassigned-#{System.unique_integer([:positive])}@example.com",
          password: "password1234",
          password_confirmation: "password1234"
        },
        authorize?: false
      )
      |> Ash.create!()

    assert ActorContext.tenant(user) == nil
  end

  test "creating with the resolved tenant sets the discriminator", %{user: user} do
    # The end-to-end shape of the failure: this create is what the agent console
    # performs on approval, and it violated a not-null constraint because the
    # tenant threaded through it was nil.
    tenant = ActorContext.tenant(user)

    unit =
      BusinessUnit
      |> Ash.Changeset.for_create(:create, %{name: "Child"}, authorize?: false, tenant: tenant)
      |> Ash.create!()

    assert unit.organization_id == tenant
    refute is_nil(unit.organization_id)
  end

  defp register(business_unit) do
    AshEnterprise.Accounts.User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{
        email: "tenant-#{System.unique_integer([:positive])}@example.com",
        password: "password1234",
        password_confirmation: "password1234"
      },
      authorize?: false
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(
      :assign_to_business_unit,
      %{owning_business_unit_id: business_unit.id},
      authorize?: false
    )
    |> Ash.update!()
  end
end
