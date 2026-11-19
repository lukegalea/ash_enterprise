defmodule AshEnterprise.Security.Changes.StampTeamGrant do
  @moduledoc """
  Puts what a team write hands to people into the write's audit metadata, so a recipe can
  tell that someone was just given a privileged role through a team.

  A person holds every role their owner teams hold (`AshEnterprise.Security.ActorContext`),
  so three writes give someone a privileged role without a `UserRole` row: a role assigned
  to a team, a person added to a team that holds one, and a deleted team that holds one
  restored. Each stamps what it grants, as `AshEnterprise.Security.Changes.StampRoleName`
  stamps a direct assignment, because a guard must not query:

    * `:team_role` (`TeamRole.assign`) stamps `role_name`, the role assigned to the team,
      and `privileged`, whether that role is privileged;
    * `:membership` (`TeamMembership.create`) and `:restore` (`Team.restore`) stamp
      `role_names`, the roles the team holds in force, `privileged_role_names`, those of
      them that are privileged, and `privileged`, whether there is any.

  A guard reads `metadata.privileged = true`. Privileged is what a role grants, not what it
  is called (`AshEnterprise.Security.PrivilegedRoles`); the names stay for the reviewer.

  A repeat that changes nothing grants nothing new, so it stamps nothing granted: an
  assignment the team already holds, or a membership the person already has (directory sync
  adds people again routinely). `privileged` is then false, `role_names` the empty list and
  `role_name` absent.

  The reads run in a `before_action`, after the action's policies admitted the caller,
  without authorization in the call's tenant, as `StampRoleName`'s do: this is the action's
  own write path, not a policy check. They override anything a caller put in the context.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Accounts.TeamMembership
  alias AshEnterprise.Security.{PrivilegedRoles, Role, TeamRole}

  @impl true
  def init(opts) do
    if opts[:as] in [:team_role, :membership, :restore],
      do: {:ok, opts},
      else: {:error, "as must be :team_role, :membership or :restore"}
  end

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      stamp(changeset, metadata(opts[:as], changeset))
    end)
  end

  defp metadata(:team_role, changeset) do
    team_id = Ash.Changeset.get_attribute(changeset, :team_id)
    role_id = Ash.Changeset.get_attribute(changeset, :role_id)
    scope_id = Ash.Changeset.get_attribute(changeset, :scoping_business_unit_id)

    if held?(team_id, role_id, scope_id, changeset.tenant) do
      %{"privileged" => false}
    else
      case roles([role_id], changeset.tenant) do
        [{_id, name, privileged?}] -> %{"role_name" => name, "privileged" => privileged?}
        _none -> %{"privileged" => false}
      end
    end
  end

  defp metadata(:membership, changeset) do
    user_id = Ash.Changeset.get_attribute(changeset, :user_id)
    team_id = Ash.Changeset.get_attribute(changeset, :team_id)

    if member?(user_id, team_id, changeset.tenant),
      do: granted([]),
      else: granted(team_roles(team_id, changeset.tenant))
  end

  defp metadata(:restore, changeset),
    do: granted(team_roles(changeset.data.id, changeset.tenant))

  defp granted(roles) do
    privileged = for {_id, name, true} <- roles, do: name

    %{
      "role_names" => Enum.map(roles, fn {_id, name, _privileged?} -> name end),
      "privileged_role_names" => privileged,
      "privileged" => privileged != []
    }
  end

  defp stamp(changeset, stamped) do
    metadata =
      changeset.context
      |> Map.get(:ash_events_metadata, %{})
      |> then(&if(is_map(&1), do: &1, else: %{}))
      |> Map.drop(["role_name", "role_names", "privileged_role_names", "privileged"])
      |> Map.merge(stamped)

    Ash.Changeset.set_context(changeset, %{ash_events_metadata: metadata})
  end

  defp held?(team_id, role_id, scope_id, tenant)
       when is_binary(team_id) and is_binary(role_id) do
    TeamRole
    |> Ash.Query.filter(
      team_id == ^team_id and role_id == ^role_id and
        scoping_business_unit_id == ^scope_id and
        (is_nil(valid_until) or valid_until > ^DateTime.utc_now())
    )
    |> Ash.exists?(authorize?: false, tenant: tenant)
  end

  defp held?(_team_id, _role_id, _scope_id, _tenant), do: false

  defp member?(user_id, team_id, tenant) when is_binary(user_id) and is_binary(team_id) do
    TeamMembership
    |> Ash.Query.filter(user_id == ^user_id and team_id == ^team_id)
    |> Ash.exists?(authorize?: false, tenant: tenant)
  end

  defp member?(_user_id, _team_id, _tenant), do: false

  # The roles the team holds in force.
  defp team_roles(team_id, tenant) when is_binary(team_id) do
    now = DateTime.utc_now()

    TeamRole
    |> Ash.Query.filter(team_id == ^team_id and (is_nil(valid_until) or valid_until > ^now))
    |> Ash.Query.select([:role_id])
    |> Ash.read!(authorize?: false, tenant: tenant)
    |> Enum.map(& &1.role_id)
    |> roles(tenant)
  end

  defp team_roles(_team_id, _tenant), do: []

  # `{id, name, privileged?}` for each role, sorted by name.
  defp roles([], _tenant), do: []

  defp roles(role_ids, tenant) do
    opts = [authorize?: false, tenant: tenant]
    privileged = PrivilegedRoles.privileged_role_ids(role_ids, opts)

    Role
    |> Ash.Query.filter(id in ^Enum.uniq(role_ids))
    |> Ash.Query.select([:id, :name])
    |> Ash.read!(opts)
    |> Enum.map(&{&1.id, &1.name, MapSet.member?(privileged, &1.id)})
    |> Enum.sort_by(&elem(&1, 1))
  end
end
