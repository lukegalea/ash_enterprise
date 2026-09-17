defmodule AshEnterprise.Platform.DemoData do
  @moduledoc """
  A populated tenant: a business-unit tree, people spread across it, teams, and
  roles that grant something real.

  ## Why this exists separately from `Seeder`

  `AshEnterprise.Platform.Seeder` provisions the *minimum viable* tenant — one
  organization, one root business unit, one Administrator, one role. That is the
  right thing for a first run and for tests, because every extra row is a row a
  test has to account for.

  It is the wrong thing for looking at the application. A hierarchy resource with
  one node demonstrates no hierarchy; a security model with one role and one user
  demonstrates no scoping. Most of what this platform argues for — grant depth
  over a business-unit subtree, teams owning records alongside users, policies
  that differ per actor — is invisible until there is a second row to compare
  against. So this module exists to make those claims *visible* rather than
  merely true.

  ## What it does not do

  Nothing here is special-cased for display. Every record is created through the
  same actions the application exposes, so the business units get their
  materialized path from `MaintainBusinessUnitPath`, the roles' grants go through
  `RolePrivilege`, and the users are registered rather than inserted. If this
  produces a screen that looks wrong, the screen is wrong.

  Idempotent by name: running it twice leaves one copy of everything, so it is
  safe to re-run against a tenant that has already been populated.
  """

  require Ash.Query

  alias AshEnterprise.Accounts
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security

  @password "password1234"

  # The tree. Depth two on one branch and depth one on the others, because a
  # uniform tree does not show that depth is what grant scope is measured in.
  @divisions [
    {"Engineering", ["Platform", "Product"]},
    {"Operations", ["Vendor management"]},
    {"Finance", []}
  ]

  # Spread deliberately: two people in one unit so ownership is not a bijection
  # with business units, and one unit (Finance) with a single person so a
  # narrowly scoped grant has something to fail to reach.
  @people [
    {"dana@example.com", "Platform"},
    {"ravi@example.com", "Platform"},
    {"mei@example.com", "Product"},
    {"tomasz@example.com", "Product"},
    {"aisha@example.com", "Engineering"},
    {"jonas@example.com", "Vendor management"},
    {"priya@example.com", "Vendor management"},
    {"soren@example.com", "Operations"},
    {"beatriz@example.com", "Finance"}
  ]

  @teams [
    {"Platform on-call", "Engineering"},
    {"Vendor review", "Vendor management"},
    {"Finance approvals", "Finance"}
  ]

  @doc """
  Populate `organization_id`'s tenant with demo records.

  Returns a map of what now exists, counted rather than listed — the caller is a
  mix task printing a summary, not something that needs the records.
  """
  @spec populate(Ash.UUID.t()) :: map
  def populate(organization_id) do
    actor = SystemActor.seed()
    tenant = organization_id

    root = root_business_unit!(tenant, actor)
    units = create_divisions(root, tenant, actor)
    users = create_people(units, root, tenant)
    teams = create_teams(units, root, tenant, actor)
    roles = create_roles(root, tenant, actor)

    assign_roles(users, roles, units, tenant, actor)

    %{
      business_units: map_size(units),
      users: length(users),
      teams: length(teams),
      roles: length(roles)
    }
  end

  defp root_business_unit!(tenant, actor) do
    Accounts.BusinessUnit
    |> Ash.Query.filter(is_nil(parent_business_unit_id))
    |> Ash.read_one!(actor: actor, tenant: tenant)
  end

  # Returns %{name => business_unit}, including the root, so later steps can
  # place a record by the name they were declared with.
  defp create_divisions(root, tenant, actor) do
    Enum.reduce(@divisions, %{root.name => root}, fn {division, children}, acc ->
      unit = upsert_business_unit(division, root, tenant, actor)

      Enum.reduce(children, Map.put(acc, division, unit), fn child, acc ->
        Map.put(acc, child, upsert_business_unit(child, unit, tenant, actor))
      end)
    end)
  end

  defp upsert_business_unit(name, parent, tenant, actor) do
    existing =
      Accounts.BusinessUnit
      |> Ash.Query.filter(name == ^name)
      |> Ash.read_one!(actor: actor, tenant: tenant)

    existing ||
      Accounts.BusinessUnit
      |> Ash.Changeset.for_create(
        :create,
        %{name: name, parent_business_unit_id: parent.id},
        actor: actor,
        tenant: tenant
      )
      |> Ash.create!()
  end

  # Registration deliberately goes through `:register_with_password` rather than
  # a seed insert: it is the action that hashes, and a demo tenant whose people
  # cannot sign in is a demo that stops at the first click.
  defp create_people(units, root, tenant) do
    Enum.map(@people, fn {email, unit_name} ->
      unit = Map.get(units, unit_name, root)

      existing =
        Accounts.User
        |> Ash.Query.filter(email == ^email)
        |> Ash.read_one!(authorize?: false)

      user =
        existing ||
          Accounts.User
          |> Ash.Changeset.for_create(
            :register_with_password,
            %{email: email, password: @password, password_confirmation: @password},
            authorize?: false
          )
          |> Ash.create!()

      user
      |> Ash.Changeset.for_update(
        :assign_to_business_unit,
        %{owning_business_unit_id: unit.id},
        authorize?: false
      )
      |> Ash.update!()
      |> Map.put(:organization_id, tenant)
    end)
  end

  defp create_teams(units, root, tenant, actor) do
    Enum.map(@teams, fn {name, unit_name} ->
      unit = Map.get(units, unit_name, root)

      existing =
        Accounts.Team
        |> Ash.Query.filter(name == ^name)
        |> Ash.read_one!(actor: actor, tenant: tenant)

      existing ||
        Accounts.Team
        |> Ash.Changeset.for_create(
          :create,
          %{name: name, owning_business_unit_id: unit.id},
          actor: actor,
          tenant: tenant
        )
        |> Ash.create!()
    end)
  end

  # Each role grants something, and the three differ in *depth* rather than only
  # in which privileges they hold -- depth is the part of this model that a list
  # of role names cannot show.
  defp create_roles(root, tenant, actor) do
    privileges = Ash.read!(Security.Privilege, actor: actor)

    reads = Enum.filter(privileges, &(&1.access_right == :read))

    people_writes =
      Enum.filter(privileges, fn privilege ->
        privilege.access_right in [:read, :write] and
          privilege.resource_name in [
            "AshEnterprise.Accounts.User",
            "AshEnterprise.Accounts.Team"
          ]
      end)

    [
      upsert_role(
        "Auditor",
        "Reads everything in the tenant and changes nothing.",
        reads,
        :global,
        root,
        tenant,
        actor
      ),
      upsert_role(
        "Team lead",
        "Manages people and teams within their own business unit and below.",
        people_writes,
        :deep,
        root,
        tenant,
        actor
      ),
      upsert_role(
        "Support desk",
        "Reads people and teams in their own business unit only.",
        Enum.filter(people_writes, &(&1.access_right == :read)),
        :local,
        root,
        tenant,
        actor
      )
    ]
  end

  defp upsert_role(name, description, privileges, depth, root, tenant, actor) do
    existing =
      Security.Role
      |> Ash.Query.filter(name == ^name)
      |> Ash.read_one!(actor: actor, tenant: tenant)

    role =
      existing ||
        Security.Role
        |> Ash.Changeset.for_create(
          :create,
          %{name: name, description: description, owning_business_unit_id: root.id},
          actor: actor,
          tenant: tenant
        )
        |> Ash.create!()

    if is_nil(existing) do
      # The Seeder raises rather than produce a role with no grants, on the
      # grounds that it looks configured and reaches nothing. The same applies
      # here for the same reason.
      grantable = Enum.filter(privileges, &grantable_at?(&1, depth))

      if grantable == [] do
        raise "demo role #{inspect(name)} would have no grants at depth #{inspect(depth)}"
      end

      for privilege <- grantable do
        Security.RolePrivilege
        |> Ash.Changeset.for_create(
          :create,
          %{role_id: role.id, privilege_id: privilege.id, depth: depth},
          actor: actor,
          tenant: tenant
        )
        |> Ash.create!()
      end
    end

    role
  end

  defp grantable_at?(privilege, :global), do: privilege.can_be_global
  defp grantable_at?(privilege, :deep), do: privilege.can_be_deep
  defp grantable_at?(privilege, :local), do: privilege.can_be_local
  defp grantable_at?(privilege, :basic), do: privilege.can_be_basic

  # Scoped to the holder's own unit, not the root: a role assigned at the root
  # reaches the whole tenant regardless of its depth, which would hide the very
  # distinction the three roles were built to show.
  defp assign_roles(users, roles, units, tenant, actor) do
    [auditor, team_lead, support] = roles

    pairs = [
      {Enum.find(users, &(&1.email |> to_string() == "aisha@example.com")), team_lead,
       units["Engineering"]},
      {Enum.find(users, &(&1.email |> to_string() == "soren@example.com")), team_lead,
       units["Operations"]},
      {Enum.find(users, &(&1.email |> to_string() == "beatriz@example.com")), auditor,
       units["Finance"]},
      {Enum.find(users, &(&1.email |> to_string() == "priya@example.com")), support,
       units["Vendor management"]}
    ]

    for {user, role, unit} <- pairs, user && unit do
      existing =
        Security.UserRole
        |> Ash.Query.filter(user_id == ^user.id and role_id == ^role.id)
        |> Ash.read_one!(actor: actor, tenant: tenant)

      existing ||
        Security.UserRole
        |> Ash.Changeset.for_create(
          :assign,
          %{user_id: user.id, role_id: role.id, scoping_business_unit_id: unit.id},
          actor: actor,
          tenant: tenant
        )
        |> Ash.create!()
    end

    :ok
  end
end
