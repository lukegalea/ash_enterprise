defmodule AshEnterprise.Security.Changes.StampPrivilegeGrant do
  @moduledoc """
  Puts into a privilege grant's audit metadata whether the grant made a role that people
  hold privileged (`privileged`), and when it did, the role's name for the reviewer
  (`role_name`), so the `security_alerts` pack can review it as it reviews a privileged role
  assigned.

  A role assigned to people today can become privileged tomorrow by one more row in
  `RolePrivilege`: nobody is assigned anything, yet every holder can now administer
  authority. The grant is stamped `privileged` when all three hold:

    * the privilege granted is privileged (`AshEnterprise.Security.Privilege.privileged?/3`);
    * the role held no privileged privilege before, so a role that already was one (the
      Administrator gaining a new resource's privileges at deploy, a repeat of a grant) adds
      no alarm of its own;
    * someone holds the role now, directly or through a team
      (`AshEnterprise.Security.PrivilegedRoles.holder_ids/2`). A role nobody holds raises
      the alarm when it is assigned, or when someone joins a team that holds it.

  The reads run in a `before_action`, after the action's policies admitted the caller,
  without authorization in the call's tenant, as `StampRoleName`'s do: this is the action's
  own write path, not a policy check. They override anything a caller put in the context.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Security.{PrivilegedRoles, Role}

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      role_id = Ash.Changeset.get_attribute(changeset, :role_id)
      privilege_id = Ash.Changeset.get_attribute(changeset, :privilege_id)
      opts = [authorize?: false, tenant: changeset.tenant]

      stamped =
        if makes_privileged?(role_id, privilege_id, opts),
          do: %{"privileged" => true, "role_name" => role_name(role_id, opts)},
          else: %{"privileged" => false}

      stamp(changeset, stamped)
    end)
  end

  # Cheapest first: most grants are of a privilege that is not privileged, and a role being
  # built (a tenant's seeding) is held by nobody yet.
  defp makes_privileged?(role_id, privilege_id, opts) do
    PrivilegedRoles.privileged_privilege?(privilege_id) and
      PrivilegedRoles.holder_ids(role_id, opts) != [] and
      not PrivilegedRoles.privileged?(role_id, opts)
  end

  defp role_name(nil, _opts), do: nil

  defp role_name(role_id, opts) do
    Role
    |> Ash.Query.filter(id == ^role_id)
    |> Ash.Query.select([:name])
    |> Ash.read_one!(opts)
    |> case do
      %{name: name} -> name
      nil -> nil
    end
  end

  defp stamp(changeset, stamped) do
    metadata =
      changeset.context
      |> Map.get(:ash_events_metadata, %{})
      |> then(&if(is_map(&1), do: &1, else: %{}))
      |> Map.drop(["role_name", "privileged"])
      |> Map.merge(Map.reject(stamped, fn {_key, value} -> is_nil(value) end))

    Ash.Changeset.set_context(changeset, %{ash_events_metadata: metadata})
  end
end
