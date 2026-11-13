defmodule AshEnterprise.Security.Changes.StampTeamGrant do
  @moduledoc """
  Puts the names of the roles a team write hands to people into the write's audit metadata,
  so a recipe can tell that someone was just made an Administrator through a team.

  A person holds every role their owner teams hold (`AshEnterprise.Security.ActorContext`),
  so three writes make someone an effective Administrator without a `UserRole` row: a role
  assigned to a team, a person added to a team that holds one, and a deleted team that holds
  one restored. Each stamps what it grants, as `AshEnterprise.Security.Changes.StampRoleName`
  stamps a direct assignment, because a guard must not query:

    * `:team_role` (`TeamRole.assign`) stamps `role_name`, the role assigned to the team;
    * `:membership` (`TeamMembership.create`) and `:restore` (`Team.restore`) stamp
      `role_names`, the roles the team holds in force, read for a guard with FEEL's
      `list contains(metadata.role_names, "Administrator")`.

  A repeat that changes nothing grants nothing new, so it stamps nothing: an assignment the
  team already holds, or a membership the person already has (directory sync adds people
  again routinely). `role_names` is then the empty list and `role_name` is absent.

  The reads run in a `before_action`, after the action's policies admitted the caller,
  without authorization in the call's tenant, as `StampRoleName`'s do: this is the action's
  own write path, not a policy check. They override anything a caller put in the context.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Accounts.TeamMembership
  alias AshEnterprise.Security.{Role, TeamRole}

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
      %{}
    else
      case names([role_id], changeset.tenant) do
        [name] -> %{"role_name" => name}
        _none -> %{}
      end
    end
  end

  defp metadata(:membership, changeset) do
    user_id = Ash.Changeset.get_attribute(changeset, :user_id)
    team_id = Ash.Changeset.get_attribute(changeset, :team_id)

    if member?(user_id, team_id, changeset.tenant),
      do: %{"role_names" => []},
      else: %{"role_names" => team_role_names(team_id, changeset.tenant)}
  end

  defp metadata(:restore, changeset),
    do: %{"role_names" => team_role_names(changeset.data.id, changeset.tenant)}

  defp stamp(changeset, stamped) do
    metadata =
      changeset.context
      |> Map.get(:ash_events_metadata, %{})
      |> then(&if(is_map(&1), do: &1, else: %{}))
      |> Map.drop(["role_name", "role_names"])
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

  # The roles the team holds in force, by name.
  defp team_role_names(team_id, tenant) when is_binary(team_id) do
    now = DateTime.utc_now()

    TeamRole
    |> Ash.Query.filter(team_id == ^team_id and (is_nil(valid_until) or valid_until > ^now))
    |> Ash.Query.select([:role_id])
    |> Ash.read!(authorize?: false, tenant: tenant)
    |> Enum.map(& &1.role_id)
    |> names(tenant)
  end

  defp team_role_names(_team_id, _tenant), do: []

  defp names([], _tenant), do: []

  defp names(role_ids, tenant) do
    Role
    |> Ash.Query.filter(id in ^Enum.uniq(role_ids))
    |> Ash.Query.select([:name])
    |> Ash.read!(authorize?: false, tenant: tenant)
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end
end
