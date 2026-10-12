defmodule AshEnterprise.Platform.PrivilegeSyncTest do
  @moduledoc """
  The boot-time privilege sync: it restores an Administrator grant a tenant
  lost (the shape of "a resource was added after provisioning"), and against
  an up-to-date deployment it writes nothing.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Platform.{PrivilegeSync, Seeder, SystemActor}
  alias AshEnterprise.Security

  test "grants an Administrator a privilege that arrived after provisioning, then is a no-op" do
    seeded = Seeder.seed_tenant(unique_name: "sync-#{System.unique_integer([:positive])}")

    # The shape of "a resource was added after this tenant was provisioned":
    # a privilege in the catalogue that no role holds.
    privilege =
      Security.Privilege
      |> Ash.Changeset.for_create(
        :create,
        %{
          resource_name: "AshEnterprise.ArrivedLater",
          access_right: :read,
          name: "prvReadArrivedLater",
          can_be_basic: true,
          can_be_local: true,
          can_be_deep: true,
          can_be_global: true
        },
        actor: SystemActor.seed()
      )
      |> Ash.create!()

    assert %{grants: grants} = PrivilegeSync.run()
    assert grants >= 1

    assert [%{depth: :global}] =
             Security.RolePrivilege
             |> Ash.Query.filter(role_id == ^seeded.role.id and privilege_id == ^privilege.id)
             |> Ash.read!(actor: SystemActor.seed(), tenant: seeded.organization.id)

    assert %{privileges: 0, grants: 0} = PrivilegeSync.run()
  end
end
