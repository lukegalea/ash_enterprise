defmodule AshEnterprise.Process.TenantPeople do
  @moduledoc """
  Which people belong to one organization, for the process engine's host callbacks: the
  escalation in `AshEnterprise.Process.AssignmentResolver.escalate/2` and the notices in
  `AshEnterprise.Process.TaskNotices`.

  `AshEnterprise.Accounts.User` is not tenant-scoped. A person belongs to an organization
  through their home business unit, so "in this tenant" is a question about business units,
  asked here the way `AshEnterprise.Accounts.Preparations.AskedToAcknowledge` asks it. Without
  it a `manager_id` that points into another organization would hand a task, and a message
  about it, to someone the tenant never admitted.

  Every read is the platform's process actor in the given tenant, in a background job, once
  per escalation or notice. None of this runs in a policy check.
  """

  require Ash.Query

  alias AshEnterprise.Accounts.{BusinessUnit, TeamMembership, User}
  alias AshEnterprise.Platform.SystemActor

  @doc """
  The active users among `ids` whose home business unit is in `tenant`, in the order of `ids`.

  Nobody for a nil tenant: a read with no tenant would answer for every organization.
  """
  @spec active_users([Ash.UUID.t()], Ash.UUID.t() | nil) :: [User.t()]
  def active_users(_ids, nil), do: []
  def active_users([], _tenant), do: []

  def active_users(ids, tenant) do
    ids = Enum.uniq(ids)

    users =
      User
      |> Ash.Query.filter(id in ^ids and lifecycle_status == :active)
      |> Ash.Query.select([:id, :email, :manager_id, :owning_business_unit_id])
      |> Ash.read!(opts(tenant))

    units = units_in(users, tenant)
    by_id = Map.new(users, &{&1.id, &1})

    for id <- ids,
        user = Map.get(by_id, id),
        user != nil,
        MapSet.member?(units, user.owning_business_unit_id),
        do: user
  end

  @doc """
  The managers (`User.manager_id`) of the people in `ids` who are themselves in `tenant`, as
  active users of `tenant`, each once, in the order of `ids`.
  """
  @spec managers([Ash.UUID.t()], Ash.UUID.t() | nil) :: [User.t()]
  def managers(ids, tenant) do
    ids
    |> active_users(tenant)
    |> Enum.map(& &1.manager_id)
    |> Enum.reject(&is_nil/1)
    |> active_users(tenant)
  end

  @doc """
  The user ids of the members of `team_ids` in `tenant`. An archived team has no members
  here, as it acts for nobody anywhere else (`AshEnterprise.Security.ActorContext`).
  """
  @spec team_member_ids([Ash.UUID.t()], Ash.UUID.t() | nil) :: [Ash.UUID.t()]
  def team_member_ids(_team_ids, nil), do: []
  def team_member_ids([], _tenant), do: []

  def team_member_ids(team_ids, tenant) do
    TeamMembership
    |> Ash.Query.filter(team_id in ^team_ids and exists(team, is_nil(archived_at)))
    |> Ash.Query.select([:user_id])
    |> Ash.read!(opts(tenant))
    |> Enum.map(& &1.user_id)
    |> Enum.uniq()
  end

  defp units_in(users, tenant) do
    unit_ids =
      users |> Enum.map(& &1.owning_business_unit_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if unit_ids == [] do
      MapSet.new()
    else
      BusinessUnit
      |> Ash.Query.filter(id in ^unit_ids)
      |> Ash.Query.select([:id])
      |> Ash.read!(opts(tenant))
      |> MapSet.new(& &1.id)
    end
  end

  defp opts(tenant), do: [actor: SystemActor.process(), tenant: tenant]
end
