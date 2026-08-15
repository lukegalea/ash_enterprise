defmodule AshEnterprise.Security.ActorContext do
  @moduledoc """
  Everything the policy engine needs about an actor, resolved **once** and carried
  on the actor for the rest of the request.

  ## Why this exists

  Evaluated naively, each of the three grant paths wants a query: "which teams am
  I in?", "what is my business unit's subtree?", "which roles do I hold and at what
  depth?", "what has been shared with me?". Run per policy check, per row, that is
  ruinous — and policy checks run on every read of every resource.

  So the rule in this codebase is absolute: **a policy check never queries.** It
  reads precomputed sets from this struct and does set membership. Building the
  struct costs about five queries per request no matter how many roles, teams or
  business units are involved; without it the cost scales with rows returned.

  Dataverse arrives at the same conclusion from the other direction — its docs
  warn that sharing is "less performant" and recommend capping hierarchy security
  at ~50 users under a manager. We precompute rather than cap.

  ## The shape of a grant

  The useful precomputed form is, per `(resource, verb)`:

      %Grant{
        global?: false,              # authorize everything
        basic?: true,                # records I own, or my teams own
        business_unit_ids: MapSet    # local units + expanded deep subtrees
      }

  Collapsing `:local` and `:deep` into one id set at build time is the key move.
  `:local` contributes one business unit; `:deep` contributes a whole subtree; by
  the time a check runs, both are just "is the record's owning business unit in
  this set?" — one `MapSet.member?/2`, or one `IN (...)` when pushed into SQL.

  ## Usage

  Built by `AshEnterpriseWeb.Plugs.LoadActorContext` for web requests, and by
  `for_actor/2` anywhere else (Oban jobs, MCP tool calls, tests). Attaching it to
  the actor means `Ash.read(Resource, actor: actor)` needs no extra plumbing.
  """

  require Ash.Query

  alias AshEnterprise.Security.AccessRight

  defmodule Grant do
    @moduledoc "Precomputed reach for one `(resource, verb)` pair."
    defstruct global?: false, basic?: false, business_unit_ids: MapSet.new()

    @type t :: %__MODULE__{
            global?: boolean(),
            basic?: boolean(),
            business_unit_ids: MapSet.t(Ash.UUID.t())
          }
  end

  defstruct [
    :user_id,
    :organization_id,
    :business_unit_id,
    team_ids: [],
    principal_ids: [],
    grants: %{},
    shared: %{},
    hierarchy: nil,
    system?: false
  ]

  @type t :: %__MODULE__{
          user_id: Ash.UUID.t() | nil,
          organization_id: Ash.UUID.t() | nil,
          business_unit_id: Ash.UUID.t() | nil,
          team_ids: [Ash.UUID.t()],
          principal_ids: [Ash.UUID.t()],
          grants: %{{String.t(), atom()} => Grant.t()},
          shared: %{{String.t(), atom()} => MapSet.t(Ash.UUID.t())},
          hierarchy: AshEnterprise.Security.Hierarchy.t() | nil,
          system?: boolean()
        }

  @doc """
  A context granting everything, for non-human actors.

  System actors bypass the role model entirely rather than being given a
  superuser role. A role would show up in the admin UI as something an
  administrator could edit or revoke, and revoking it would break background
  processing in a way that looks like a permissions bug.

  Every write still records *which* system actor was responsible — see
  `AshEnterprise.Platform.SystemActor`.
  """
  def system(organization_id \\ nil) do
    %__MODULE__{system?: true, organization_id: organization_id}
  end

  @doc """
  Builds the context for a user.

  Idempotent and cheap to call twice: if the actor already carries a context,
  it is returned as-is.
  """
  def for_actor(actor, opts \\ [])

  def for_actor(%__MODULE__{} = context, _opts), do: context
  def for_actor(%AshEnterprise.Platform.SystemActor{}, opts), do: system(opts[:tenant])
  def for_actor(nil, _opts), do: %__MODULE__{}

  def for_actor(%{__struct__: _} = user, opts) do
    case Map.get(user, :__ash_enterprise_context__) do
      %__MODULE__{} = context -> context
      _ -> build(user, opts)
    end
  end

  def for_actor(_other, _opts), do: %__MODULE__{}

  @doc """
  Resolves an actor's full authorization context. Roughly five queries,
  independent of how many roles or business units are involved.
  """
  def build(user, opts \\ []) do
    tenant = opts[:tenant] || Map.get(user, :organization_id)
    user_id = Map.get(user, :id)
    business_unit_id = Map.get(user, :owning_business_unit_id)

    team_ids = load_team_ids(user_id, tenant)
    principal_ids = [user_id | team_ids] |> Enum.reject(&is_nil/1)

    role_assignments = load_role_assignments(user_id, team_ids, tenant)
    grants = build_grants(role_assignments, tenant)
    shared = load_shared(principal_ids, tenant)

    %__MODULE__{
      user_id: user_id,
      organization_id: tenant,
      business_unit_id: business_unit_id,
      team_ids: team_ids,
      principal_ids: principal_ids,
      grants: grants,
      shared: shared,
      # Costs nothing when hierarchy security is disabled (the default): resolve/2
      # returns an empty struct without querying.
      hierarchy: AshEnterprise.Security.Hierarchy.resolve(user, tenant),
      system?: false
    }
  end

  @doc "The precomputed grant for a `(resource, verb)`, or an empty grant."
  def grant(%__MODULE__{} = context, resource, verb) do
    Map.get(context.grants, {resource_name(resource), verb}, %Grant{})
  end

  @doc """
  Record ids of `resource` explicitly shared with this actor, granting `verb`.

  Returns a list because it is destined for an `IN (...)` filter. Sharing is
  meant to be exceptional; if this list is routinely large, the access should be
  a role, not a pile of shares.
  """
  def shared_record_ids(%__MODULE__{} = context, resource, verb) do
    context.shared
    |> Map.get({resource_name(resource), verb}, MapSet.new())
    |> MapSet.to_list()
  end

  @doc """
  The tenant an actor belongs to, without querying.

  Call this rather than reaching for `actor.organization_id`. Not every actor
  resource *has* that attribute — `User` is `tenant?: false`, because a user is
  scoped by the business unit that owns them rather than carrying the tenant
  directly — so the plain field access raises `KeyError` on exactly the actor type
  most code holds. The resolved context, attached once per request by
  `AshEnterpriseWeb.Plugs.LoadActorContext`, already knows the answer.
  """
  def tenant(actor), do: for_actor(actor).organization_id

  @doc "Attaches a context to a user struct so it travels as the actor."
  def attach(user, %__MODULE__{} = context) do
    Map.put(user, :__ash_enterprise_context__, context)
  end

  defp resource_name(resource) when is_atom(resource), do: inspect(resource)
  defp resource_name(resource) when is_binary(resource), do: resource

  # --- loading ----------------------------------------------------------------

  defp load_team_ids(nil, _tenant), do: []

  defp load_team_ids(user_id, tenant) do
    AshEnterprise.Accounts.TeamMembership
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.Query.select([:team_id])
    |> read_all(tenant)
    |> Enum.map(& &1.team_id)
  end

  # Direct roles plus roles held through teams, each with the business unit the
  # grant is scoped to. One query per source rather than per role.
  defp load_role_assignments(nil, _team_ids, _tenant), do: []

  defp load_role_assignments(user_id, team_ids, tenant) do
    direct =
      AshEnterprise.Security.UserRole
      |> Ash.Query.filter(user_id == ^user_id)
      |> Ash.Query.select([:role_id, :scoping_business_unit_id])
      |> read_all(tenant)

    via_teams =
      if team_ids == [] do
        []
      else
        AshEnterprise.Security.TeamRole
        |> Ash.Query.filter(team_id in ^team_ids)
        |> Ash.Query.select([:role_id, :scoping_business_unit_id])
        |> read_all(tenant)
      end

    Enum.map(direct ++ via_teams, &{&1.role_id, &1.scoping_business_unit_id})
  end

  defp build_grants([], _tenant), do: %{}

  defp build_grants(assignments, tenant) do
    role_ids = assignments |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    role_privileges =
      AshEnterprise.Security.RolePrivilege
      |> Ash.Query.filter(role_id in ^role_ids)
      |> Ash.Query.load(:privilege)
      |> read_all(tenant)

    by_role = Enum.group_by(role_privileges, & &1.role_id)

    # Expand every :deep grant's subtree in ONE query rather than per grant.
    deep_scopes =
      for {role_id, scope_bu} <- assignments,
          rp <- Map.get(by_role, role_id, []),
          rp.depth == :deep,
          not is_nil(scope_bu),
          do: scope_bu

    subtrees = load_subtrees(Enum.uniq(deep_scopes), tenant)

    # Flattened to (role_privilege, scoping_business_unit) pairs first, so the
    # accumulation is a single reduce rather than a nested one. Same result,
    # and the union logic in apply_grant/5 stays the only thing to read.
    for {role_id, scope_bu} <- assignments,
        role_privilege <- Map.get(by_role, role_id, []),
        not is_nil(role_privilege.privilege),
        reduce: %{} do
      acc ->
        apply_grant(acc, role_privilege.privilege, role_privilege.depth, scope_bu, subtrees)
    end
  end

  defp apply_grant(acc, privilege, depth, scope_bu, subtrees) do
    key = {privilege.resource_name, privilege.access_right}
    grant = Map.get(acc, key, %Grant{})

    grant =
      case depth do
        :global ->
          %{grant | global?: true}

        :deep ->
          ids = Map.get(subtrees, scope_bu, MapSet.new())
          %{grant | business_unit_ids: MapSet.union(grant.business_unit_ids, ids)}

        :local ->
          if scope_bu do
            %{grant | business_unit_ids: MapSet.put(grant.business_unit_ids, scope_bu)}
          else
            grant
          end

        :basic ->
          %{grant | basic?: true}

        _ ->
          grant
      end

    Map.put(acc, key, grant)
  end

  defp load_subtrees([], _tenant), do: %{}

  defp load_subtrees(business_unit_ids, tenant) do
    # Resolve each root's path, then fetch every descendant of any of them in a
    # single prefix-matching query, and partition the results back by root.
    roots =
      AshEnterprise.Accounts.BusinessUnit
      |> Ash.Query.filter(id in ^business_unit_ids)
      |> Ash.Query.select([:id, :path])
      |> read_all(tenant)

    case roots do
      [] ->
        %{}

      roots ->
        prefixes = Enum.map(roots, & &1.path)

        descendants =
          AshEnterprise.Accounts.BusinessUnit
          |> Ash.Query.filter(fragment("? LIKE ANY (?)", path, ^Enum.map(prefixes, &(&1 <> "%"))))
          |> Ash.Query.select([:id, :path])
          |> read_all(tenant)

        Map.new(roots, fn root ->
          ids =
            descendants
            |> Enum.filter(&String.starts_with?(&1.path, root.path))
            |> MapSet.new(& &1.id)

          {root.id, ids}
        end)
    end
  end

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

  # Reads here are structural: they resolve who the actor *is*, and must run
  # before any authorization decision can be made. Authorizing them would be
  # circular -- you would need a context to build the context.
  #
  # A failure degrades to "no access" rather than crashing the request, which is
  # the right direction to fail. But it is LOUD: an empty context is
  # indistinguishable from a user who genuinely has no roles, so a silently
  # swallowed error here presents as a mystifying permissions complaint from one
  # user and nothing in the logs. Log it with the query so the cause is
  # recoverable.
  defp read_all(query, tenant) do
    case Ash.read(query, authorize?: false, tenant: tenant) do
      {:ok, results} ->
        results

      {:error, error} ->
        require Logger

        Logger.error("""
        ActorContext could not resolve #{inspect(query.resource)}; the actor will \
        be treated as having no access from this source.

        #{Exception.message(error)}\
        """)

        []
    end
  end
end
