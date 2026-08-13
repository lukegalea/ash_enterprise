defmodule AshEnterprise.Security.Hierarchy do
  @moduledoc """
  Grant path 3: hierarchy security. Resolves who an actor sits above.

  Managers reach their reports' records without holding any role that names those
  records. Two mutually exclusive models, **disabled by default**, matching
  Dataverse:

    * `:manager` — walks `User.manager_id`. Normally confined to the manager's own
      business unit or its parent.
    * `:position` — walks `Position.parent_position_id` along the actor's **direct
      ancestor path**, and works *across* business units.

  ## The asymmetry that defines the model

  > *Direct reports:* Read, Write, Append, AppendTo.
  > *Everyone further down the chain:* **Read only.**

  A manager can act on their immediate reports' work and merely observe the rest.
  Collapsing that into "managers can do anything below them" is the single most
  consequential way to get this wrong, because it silently grants write access
  across an entire org chart.

  ## What is reachable, and what is not

  A manager reaches records **owned by** a subordinate or by a team a subordinate
  belongs to, and records **directly shared with** them.

  They do **not** inherit the subordinate's own broader access. If a report holds
  a `:global` role, their manager does not thereby see everything — only what that
  report owns or was given. This is materially cheaper than transitive closure and
  is the semantic Dataverse actually specifies; replicating it matters, because
  the intuitive "managers see everything their reports see" would make one senior
  hire equivalent to a global grant.

  ## Depth

  Bounded by `max_depth` (default 3). Dataverse recommends keeping an effective
  hierarchy under ~50 users per manager; the bound is what keeps the resolution
  cost fixed rather than proportional to the org chart.

  ## Configuration

      config :ash_enterprise, :hierarchy_security,
        mode: :manager,                             # :disabled | :manager | :position
        max_depth: 3,
        managers_must_share_business_unit?: true

  Disabled by default because it is an *additional* grant path: switching it on
  widens access for everyone with a report, and that should be a deliberate act.
  """

  require Ash.Query

  alias AshEnterprise.Security.AccessRight

  defstruct mode: :disabled,
            direct_principal_ids: [],
            indirect_principal_ids: [],
            direct_shared: %{},
            indirect_shared: %{}

  @type t :: %__MODULE__{
          mode: :disabled | :manager | :position,
          direct_principal_ids: [Ash.UUID.t()],
          indirect_principal_ids: [Ash.UUID.t()],
          direct_shared: %{{String.t(), atom()} => MapSet.t(Ash.UUID.t())},
          indirect_shared: %{{String.t(), atom()} => MapSet.t(Ash.UUID.t())}
        }

  @doc "Verbs a manager gets over a **direct** report's records."
  def direct_verbs, do: [:read, :write, :append, :append_to]

  @doc "Verbs a manager gets over an **indirect** subordinate's records."
  def indirect_verbs, do: [:read]

  @doc "The configured mode, or `:disabled`."
  def mode do
    config()[:mode] || :disabled
  end

  defp config, do: Application.get_env(:ash_enterprise, :hierarchy_security, [])
  defp max_depth, do: config()[:max_depth] || 3

  defp managers_must_share_business_unit? do
    Keyword.get(config(), :managers_must_share_business_unit?, true)
  end

  @doc """
  Resolves the hierarchy below `user`.

  Returns an empty struct when hierarchy security is disabled, which makes the
  check contribute nothing to the union rather than erroring.
  """
  def resolve(user, tenant) do
    case mode() do
      :disabled -> %__MODULE__{}
      :manager -> build(user, tenant, &manager_reports/3, :manager)
      :position -> build(user, tenant, &position_reports/3, :position)
    end
  end

  defp build(user, tenant, walker, mode) do
    user_id = Map.get(user, :id)

    if is_nil(user_id) do
      %__MODULE__{}
    else
      {direct_user_ids, indirect_user_ids} = walker.(user, tenant, max_depth())

      direct_principals = expand_principals(direct_user_ids, tenant)
      indirect_principals = expand_principals(indirect_user_ids, tenant)

      %__MODULE__{
        mode: mode,
        direct_principal_ids: direct_principals,
        indirect_principal_ids: indirect_principals,
        direct_shared: load_shared(direct_principals, tenant),
        indirect_shared: load_shared(indirect_principals, tenant)
      }
    end
  end

  # --- manager model ----------------------------------------------------------

  # Breadth-first, one query per level, bounded by max_depth. Positions and
  # management chains are shallow, so this is a handful of small queries -- and
  # unlike a recursive CTE it hands back the direct/indirect split for free,
  # which is the distinction the whole model turns on.
  defp manager_reports(user, tenant, depth) do
    user_id = Map.get(user, :id)
    allowed_bu_ids = allowed_business_units(user, tenant)

    walk_levels([user_id], depth, fn ids ->
      AshEnterprise.Accounts.User
      |> Ash.Query.filter(manager_id in ^ids)
      |> Ash.Query.select([:id, :owning_business_unit_id])
      |> read_all(tenant)
      |> filter_by_business_unit(allowed_bu_ids)
      |> Enum.map(& &1.id)
    end)
  end

  # Dataverse's `ManagersMustBeInSameOrParentBusinessUnitAsReports`, default true:
  # a manager only reaches reports in their own business unit or beneath it.
  #
  # This is not a detail. Without it, a manager transferred to a different part of
  # the company keeps reaching their former reports' records indefinitely, because
  # the manager_id edges outlive the reorganization -- and nothing in the role
  # model would show that access exists.
  #
  # Returns `nil` when unrestricted, meaning "do not filter".
  defp allowed_business_units(user, tenant) do
    if managers_must_share_business_unit?() do
      case Map.get(user, :owning_business_unit_id) do
        nil ->
          # A manager with no business unit reaches nobody under this rule,
          # rather than everybody.
          MapSet.new()

        bu_id ->
          subtree_ids(bu_id, tenant)
      end
    end
  end

  defp subtree_ids(business_unit_id, tenant) do
    AshEnterprise.Accounts.BusinessUnit
    |> Ash.Query.filter(id == ^business_unit_id)
    |> Ash.Query.select([:path])
    |> Ash.read_one(authorize?: false, tenant: tenant)
    |> case do
      {:ok, %{path: path}} ->
        AshEnterprise.Accounts.BusinessUnit
        |> Ash.Query.filter(like(path, ^(path <> "%")))
        |> Ash.Query.select([:id])
        |> read_all(tenant)
        |> MapSet.new(& &1.id)

      _ ->
        MapSet.new()
    end
  end

  defp filter_by_business_unit(users, nil), do: users

  defp filter_by_business_unit(users, allowed) do
    Enum.filter(users, fn user ->
      user.owning_business_unit_id && MapSet.member?(allowed, user.owning_business_unit_id)
    end)
  end

  # --- position model ---------------------------------------------------------

  defp position_reports(user, tenant, depth) do
    case Map.get(user, :position_id) do
      nil ->
        {[], []}

      position_id ->
        {direct_positions, indirect_positions} =
          walk_levels([position_id], depth, fn ids ->
            AshEnterprise.Accounts.Position
            |> Ash.Query.filter(parent_position_id in ^ids)
            |> Ash.Query.select([:id])
            |> read_all(tenant)
            |> Enum.map(& &1.id)
          end)

        {users_in_positions(direct_positions, tenant),
         users_in_positions(indirect_positions, tenant)}
    end
  end

  defp users_in_positions([], _tenant), do: []

  defp users_in_positions(position_ids, tenant) do
    AshEnterprise.Accounts.User
    |> Ash.Query.filter(position_id in ^position_ids)
    |> Ash.Query.select([:id])
    |> read_all(tenant)
    |> Enum.map(& &1.id)
  end

  # --- shared walking ---------------------------------------------------------

  # Returns {level 1, levels 2..depth}. Level 1 is "direct"; the rest is
  # "indirect" and gets read-only treatment.
  defp walk_levels(roots, depth, fetch_children) do
    first = fetch_children.(roots)

    {rest, _seen} =
      Enum.reduce(2..max(depth, 1)//1, {[], MapSet.new(roots ++ first)}, fn
        _level, {acc, seen} ->
          frontier = if acc == [], do: first, else: acc
          # A cycle in the data would otherwise revisit forever; `seen` bounds it
          # even though the validations should have prevented one.
          next =
            frontier
            |> fetch_children.()
            |> Enum.reject(&MapSet.member?(seen, &1))

          {acc ++ next, MapSet.union(seen, MapSet.new(next))}
      end)

    {Enum.uniq(first), Enum.uniq(rest)}
  end

  # A subordinate's records may be owned by them OR by a team they belong to.
  defp expand_principals([], _tenant), do: []

  defp expand_principals(user_ids, tenant) do
    team_ids =
      AshEnterprise.Accounts.TeamMembership
      |> Ash.Query.filter(user_id in ^user_ids)
      |> Ash.Query.select([:team_id])
      |> read_all(tenant)
      |> Enum.map(& &1.team_id)

    Enum.uniq(user_ids ++ team_ids)
  end

  # Records directly shared with a subordinate are reachable by their manager.
  defp load_shared([], _tenant), do: %{}

  defp load_shared(principal_ids, tenant) do
    AshEnterprise.Security.AccessGrant
    |> Ash.Query.filter(principal_id in ^principal_ids)
    |> read_all(tenant)
    |> Enum.reduce(%{}, fn grant, acc ->
      mask = Bitwise.bor(grant.rights_mask || 0, grant.inherited_rights_mask || 0)

      mask
      |> AccessRight.from_mask()
      |> Enum.reduce(acc, fn verb, acc ->
        Map.update(
          acc,
          {grant.resource_name, verb},
          MapSet.new([grant.record_id]),
          &MapSet.put(&1, grant.record_id)
        )
      end)
    end)
  end

  defp read_all(query, tenant) do
    case Ash.read(query, authorize?: false, tenant: tenant) do
      {:ok, results} -> results
      {:error, _} -> []
    end
  end
end
