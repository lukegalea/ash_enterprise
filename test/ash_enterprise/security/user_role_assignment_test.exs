defmodule AshEnterprise.Security.UserRoleAssignmentTest do
  @moduledoc """
  Assigning a role is idempotent while the assignment is in force, and a revoked
  assignment does not stand in the way of assigning the role again: `assign` upserts on
  `unique_assignment`, which counts only assignments that are not archived. Before, the
  upsert found the archived row, updated it and left it archived, so a revoked role
  could never be given back.
  """

  use AshEnterprise.DataCase, async: true

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  require Ash.Query

  alias AshEnterprise.Credentialing.Credential
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security
  alias AshEnterprise.Security.ActorContext

  defp in_force(user_id, tenant) do
    Security.UserRole
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  defp assign!(assignment, tenant) do
    Security.UserRole
    |> Ash.Changeset.for_create(
      :assign,
      Map.take(assignment, [:user_id, :role_id, :scoping_business_unit_id]),
      actor: SystemActor.seed(),
      tenant: tenant
    )
    |> Ash.create!()
  end

  # The grant the member's role carries, as their context is built now.
  defp may_read?(member) do
    context = ActorContext.build(member.user, tenant: member.tenant)
    Map.has_key?(context.grants, {inspect(Credential), :read})
  end

  test "a revoked role can be assigned again, and assigning it twice is still one assignment" do
    admin = tenant!()

    member =
      member!(admin, "Reader #{System.unique_integer([:positive])}", [
        {Credential, :read, :global}
      ])

    [assignment] = in_force(member.user.id, admin.tenant)
    assert may_read?(member)

    # Twice is the same intent: one assignment in force.
    assert assign!(assignment, admin.tenant).id == assignment.id
    assert [_one] = in_force(member.user.id, admin.tenant)

    Ash.destroy!(assignment, actor: SystemActor.seed(), tenant: admin.tenant)
    assert in_force(member.user.id, admin.tenant) == []
    refute may_read?(member)

    again = assign!(assignment, admin.tenant)
    assert again.id != assignment.id
    assert [%{id: id}] = in_force(member.user.id, admin.tenant)
    assert id == again.id
    assert may_read?(member)
  end
end
