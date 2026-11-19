defmodule AshEnterprise.Security.PrivilegedRoles do
  @moduledoc """
  Which roles are privileged, by what they grant, and who holds a role: the reads behind
  the `security_alerts` pack's stamps (`AshEnterprise.Security.Changes.StampRoleName`,
  `StampTeamGrant`, `StampPrivilegeGrant`) and its review's `role_holders` exclusion.

  A role is privileged when it holds a privileged privilege
  (`AshEnterprise.Security.Privilege.privileged?/3`), whatever its name: a renamed role is
  as privileged as it was, and a role called "Administrator" that grants nothing is not.

  ## Never from a policy

  These read. They run on an action's own write path, in a `before_action` after the
  action's policies admitted the caller, or in the review's assignment resolver, never in
  a policy check. `opts` carries the reads' tenant and authorization: the stamps pass
  `authorize?: false` and the call's tenant, as `StampRoleName` always has.
  """

  require Ash.Query

  alias AshEnterprise.Accounts.TeamMembership
  alias AshEnterprise.Security.{Privilege, RolePrivilege, TeamRole, UserRole}

  @doc """
  The ids among `role_ids` whose roles hold a privileged privilege, in the tenant in `opts`.
  A revoked grant (archived) does not count.
  """
  @spec privileged_role_ids([Ash.UUID.t()], keyword()) :: MapSet.t(Ash.UUID.t())
  def privileged_role_ids(role_ids, opts) do
    case role_ids |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        MapSet.new()

      role_ids ->
        privilege_ids = privileged_privilege_ids()

        RolePrivilege
        |> Ash.Query.filter(role_id in ^role_ids and privilege_id in ^privilege_ids)
        |> Ash.Query.select([:role_id])
        |> Ash.read!(opts)
        |> MapSet.new(& &1.role_id)
    end
  end

  @doc "Whether the role `role_id` holds a privileged privilege."
  @spec privileged?(Ash.UUID.t() | nil, keyword()) :: boolean()
  def privileged?(role_id, opts),
    do: MapSet.member?(privileged_role_ids([role_id], opts), role_id)

  @doc """
  Whether the privilege `privilege_id` is privileged (`Privilege.privileged?/3`). An
  unknown id is not.
  """
  @spec privileged_privilege?(Ash.UUID.t() | nil) :: boolean()
  def privileged_privilege?(nil), do: false

  def privileged_privilege?(privilege_id) do
    Privilege
    |> Ash.Query.filter(id == ^privilege_id)
    |> Ash.Query.select([:resource_name, :access_right])
    |> Ash.read_one!(authorize?: false)
    |> case do
      %Privilege{resource_name: name, access_right: verb} -> Privilege.privileged?(name, verb)
      nil -> false
    end
  end

  @doc """
  The people who hold the role `role_id` now, in the tenant in `opts`: assigned it directly,
  or members of a team that holds it, while the assignment is in force (`valid_until` unset
  or later than now) and the team is not deleted. What `AshEnterprise.Security.ActorContext`
  counts.
  """
  @spec holder_ids(Ash.UUID.t() | nil, keyword()) :: [Ash.UUID.t()]
  def holder_ids(nil, _opts), do: []

  def holder_ids(role_id, opts) do
    now = DateTime.utc_now()

    direct =
      UserRole
      |> Ash.Query.filter(role_id == ^role_id and (is_nil(valid_until) or valid_until > ^now))
      |> Ash.Query.select([:user_id])
      |> Ash.read!(opts)
      |> Enum.map(& &1.user_id)

    team_ids =
      TeamRole
      |> Ash.Query.filter(role_id == ^role_id and (is_nil(valid_until) or valid_until > ^now))
      |> Ash.Query.select([:team_id])
      |> Ash.read!(opts)
      |> Enum.map(& &1.team_id)

    Enum.uniq(direct ++ members(team_ids, opts))
  end

  defp members([], _opts), do: []

  defp members(team_ids, opts) do
    TeamMembership
    |> Ash.Query.filter(team_id in ^Enum.uniq(team_ids) and exists(team, is_nil(archived_at)))
    |> Ash.Query.select([:user_id])
    |> Ash.read!(opts)
    |> Enum.map(& &1.user_id)
  end

  # The catalogue is the same for every tenant and small: read it and keep the ids of the
  # privileged rows.
  defp privileged_privilege_ids do
    pairs = Privilege.privileged_pairs()

    Privilege
    |> Ash.Query.select([:id, :resource_name, :access_right])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&Privilege.privileged?(&1.resource_name, &1.access_right, pairs))
    |> Enum.map(& &1.id)
  end
end
