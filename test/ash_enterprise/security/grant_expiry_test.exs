defmodule AshEnterprise.Security.GrantExpiryTest do
  @moduledoc """
  A role grant may carry `valid_until`. An expired grant contributes nothing to
  the actor context: not at a boundary, not through a team, and not when the
  stored value is the only thing that changed.

  The boundary is exclusive: at `valid_until` itself the grant is already gone.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  require Ash.Query

  alias AshEnterprise.Accounts.{Team, TeamMembership}
  alias AshEnterprise.Credentialing.Credential
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security
  alias AshEnterprise.Security.ActorContext

  @grant {Credential, :read, :global}

  defp may_read?(member, now \\ DateTime.utc_now()) do
    context = ActorContext.build(member.user, tenant: member.tenant, now: now)
    Map.has_key?(context.grants, {inspect(Credential), :read})
  end

  defp role_row(member) do
    Security.UserRole
    |> Ash.Query.filter(user_id == ^member.user.id)
    |> Ash.read_one!(authorize?: false, tenant: member.tenant)
  end

  defp set_valid_until!(row, tenant, value) do
    row
    |> Ash.Changeset.for_update(:set_valid_until, %{valid_until: value},
      actor: SystemActor.seed(),
      tenant: tenant
    )
    |> Ash.update!()
  end

  setup do
    admin = tenant!()
    member = member!(admin, "Reader #{System.unique_integer([:positive])}", [@grant])
    %{admin: admin, member: member, row: role_row(member)}
  end

  test "a grant with no end is in force", %{member: member, row: row} do
    assert row.valid_until == nil
    assert may_read?(member)
  end

  test "a grant is in force before valid_until, and gone at it", %{member: member, row: row} do
    until = ~U[2026-12-01 09:00:00.000000Z]
    set_valid_until!(row, member.tenant, until)

    assert may_read?(member, DateTime.add(until, -1, :microsecond))
    refute may_read?(member, until)
    refute may_read?(member, DateTime.add(until, 1, :microsecond))
  end

  test "a grant that expired in the past grants nothing now", %{member: member, row: row} do
    set_valid_until!(row, member.tenant, DateTime.add(DateTime.utc_now(), -60))
    refute may_read?(member)
  end

  test "extending an expired grant brings it back", %{member: member, row: row} do
    row = set_valid_until!(row, member.tenant, DateTime.add(DateTime.utc_now(), -60))
    refute may_read?(member)

    set_valid_until!(row, member.tenant, DateTime.add(DateTime.utc_now(), 3600))
    assert may_read?(member)
  end

  test "clearing valid_until makes the grant open-ended again", %{member: member, row: row} do
    row = set_valid_until!(row, member.tenant, DateTime.add(DateTime.utc_now(), -60))
    set_valid_until!(row, member.tenant, nil)
    assert may_read?(member)
  end

  test "one expired grant does not take away another the user holds", %{
    admin: admin,
    member: member,
    row: row
  } do
    other =
      member!(admin, "Other #{System.unique_integer([:positive])}", [{Credential, :read, :global}])

    Security.UserRole
    |> Ash.Changeset.for_create(
      :assign,
      %{
        user_id: member.user.id,
        role_id: role_row(other).role_id,
        scoping_business_unit_id: admin.user.owning_business_unit_id
      },
      actor: SystemActor.seed(),
      tenant: member.tenant
    )
    |> Ash.create!()

    set_valid_until!(row, member.tenant, DateTime.add(DateTime.utc_now(), -60))
    assert may_read?(member)
  end

  test "a role held through a team expires with its own valid_until", %{admin: admin} do
    actor = SystemActor.seed()
    tenant = admin.tenant

    holder = member!(admin, "Holder #{System.unique_integer([:positive])}", [@grant])
    role_id = role_row(holder).role_id
    plain = member!(admin, "Plain #{System.unique_integer([:positive])}", [])
    unit = admin.user.owning_business_unit_id

    team =
      Team
      |> Ash.Changeset.for_create(
        :create,
        %{name: "T #{System.unique_integer([:positive])}", owning_business_unit_id: unit},
        actor: actor,
        tenant: tenant
      )
      |> Ash.create!()

    TeamMembership
    |> Ash.Changeset.for_create(:create, %{team_id: team.id, user_id: plain.user.id},
      actor: actor,
      tenant: tenant
    )
    |> Ash.create!()

    team_role =
      Security.TeamRole
      |> Ash.Changeset.for_create(
        :assign,
        %{
          team_id: team.id,
          role_id: role_id,
          scoping_business_unit_id: unit,
          valid_until: ~U[2026-12-01 09:00:00.000000Z]
        },
        actor: actor,
        tenant: tenant
      )
      |> Ash.create!()

    assert may_read?(plain, ~U[2026-12-01 08:59:59.000000Z])
    refute may_read?(plain, ~U[2026-12-01 09:00:00.000000Z])
    assert team_role.valid_until == ~U[2026-12-01 09:00:00.000000Z]
  end

  test "a grant can be created already carrying an end", %{admin: admin, member: member} do
    other_role = role_row(member).role_id
    other = member!(admin, "N #{System.unique_integer([:positive])}", [])

    until = DateTime.add(DateTime.utc_now(), 3600)

    row =
      Security.UserRole
      |> Ash.Changeset.for_create(
        :assign,
        %{
          user_id: other.user.id,
          role_id: other_role,
          scoping_business_unit_id: admin.user.owning_business_unit_id,
          valid_until: until
        },
        actor: SystemActor.seed(),
        tenant: member.tenant
      )
      |> Ash.create!()

    assert row.valid_until == until
    assert may_read?(other)
    refute may_read?(other, DateTime.add(until, 1, :second))
  end
end
