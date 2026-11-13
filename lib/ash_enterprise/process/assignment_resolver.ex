defmodule AshEnterprise.Process.AssignmentResolver do
  @moduledoc """
  Turns a diagram's candidate clauses into the set of principals who may act on a task.

  `ash_bpmn` refuses to know what a manager is, or what "the Requisition Approver role, scoped
  to the owning business unit" means. Those are facts about *this* organization's model, so
  this module is where a clause like `kind="manager_of" of="subject.created_by_id"` becomes a
  list of user ids — and it is the single most consequential integration point in the whole
  adoption, because it is where the authorization model gets inverted.

  ## The inversion, and why it is paid for once

  `AshEnterprise.Security.ActorContext` answers *what can this actor reach*. A task list needs
  the opposite: *who can reach this task*. There is no cheap way to run the grant model
  backwards per request, so the inversion happens **once, when the task is created**, and its
  answer is written down as `TaskCandidate` rows.

  Three things follow, and each solves a problem that would otherwise be a compromise:

    * The task list is one indexed join on the actor's `principal_ids`, which `ActorContext`
      already computes. No policy evaluation per row, so
      [thesis 3](../../../docs/manifesto/03-authorization-is-data.md)'s performance rule is
      respected rather than excepted.
    * Maker-checker becomes **subtraction during data construction** rather than a `forbid_if`.
      `excluding` removes principals before the rows are written, so the policy that guards
      claiming a task stays a pure union of grants and the additive model survives intact.
    * Delegation is a row, not a rule change.

  ## Honest limits

  **Staleness.** A candidate set resolved on Monday does not know about Tuesday's
  reorganisation. The rows are an index, not the authority: `ash_bpmn` re-checks at claim time,
  and a discrepancy is an event you can see — because a candidate list that silently disagrees
  with the role model is a bug you want surfaced.

  **Cardinality.** `role: "Employee"` at organization scope on a large tenant would materialise
  one row per user per task. `@max_candidates` refuses loudly above a bound rather than
  quietly making this the largest table in the database. Refusing is the right failure: a task
  nobody can claim is visible in minutes, a table that grows without limit is visible in
  months.

  ## Never queries in a policy

  This module *does* query, and that is not a contradiction. Non-negotiable #3 forbids a
  **policy check** from querying, because that runs per row per request. This runs once per
  task, in a background job, and writes its answer down precisely so that the policy check
  afterwards does not have to.
  """

  @behaviour AshBpmn.AssignmentResolver

  require Ash.Query
  require Logger

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Security.UserRole

  # Above this, materialising is the wrong strategy and pretending otherwise makes a table
  # nobody meant to create. See "Honest limits".
  @max_candidates 5_000

  @impl true
  def candidates(specs, ctx) do
    specs
    |> Enum.flat_map(&resolve_clause(&1, ctx))
    |> Enum.uniq_by(&{&1.type, &1.id})
    |> case do
      resolved when length(resolved) > @max_candidates ->
        {:error,
         {:too_many_candidates, length(resolved), @max_candidates,
          "refusing to materialise a candidate list this large; narrow the clause's scope"}}

      resolved ->
        {:ok, resolved}
    end
  end

  @impl true
  def exclusions(specs, ctx) do
    {:ok, specs |> Enum.flat_map(&resolve_exclusion(&1, ctx)) |> Enum.uniq()}
  end

  # ── nobody eligible ──────────────────────────────────────────────────────

  @default_fallback [%{"kind" => "role", "of" => "Platform Operator"}]

  @doc """
  Who gets a task whose candidates, minus its exclusions, left nobody: the
  clauses in `fallback_specs/0`, resolved in the task's tenant like any other
  clause.

  The case this answers was found on a real deployment: a tenant's only
  Administrator granted a role, the review excluded the granter, and the task
  had no candidates. `ash_bpmn` subtracts the exclusions from this answer again
  (so the granter and the person the change is about never come back in
  through it), writes the task with whoever remains and records a
  `:no_eligible_candidate` event, from which
  `AshEnterprise.Bpmn.Changes.RecordUnassignableFinding` raises a finding in
  the same transaction. A fallback that resolves nobody is still recorded:
  the task exists, nobody can act on it, and the finding says so.
  """
  @impl true
  def no_eligible_candidate(_info, ctx), do: candidates(fallback_specs(), ctx)

  @doc """
  The candidate clauses a task with nobody eligible falls back to.

  Configured as `config :ash_enterprise, #{inspect(__MODULE__)}, no_eligible_candidate: [...]`,
  in the clause shape a diagram uses. Defaults to the `Platform Operator` role
  (`mix ash_enterprise.platform.grant_operator`). That role is held in the
  operator's own tenant, so in any other tenant the default resolves nobody
  unless that tenant has a role of the same name: a fallback never crosses
  tenants.
  """
  @spec fallback_specs() :: [map()]
  def fallback_specs do
    :ash_enterprise
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:no_eligible_candidate, @default_fallback)
  end

  # ── who a person acts as ─────────────────────────────────────────────────

  @doc """
  The teams a person acts for, so the engine's candidacy checks
  (`AshBpmn.Candidacy`) match `:team` candidate rows and team assignees.

  Answered without a query whenever the answer is already known: a principal
  map that carries `:team_ids` (as `AshEnterprise.Security.ActorContext`
  passes while it is being built), or an actor carrying its precomputed
  `ActorContext`. Otherwise — a delegate named by id, an actor built outside a
  request — the person's team memberships are read once, as the system, in
  the tenant. This runs once per claim, completion or delegation, never in a
  policy check.
  """
  @impl true
  def team_ids(principal, ctx) do
    case principal do
      %{team_ids: ids} when is_list(ids) ->
        ids

      %{__ash_enterprise_context__: %AshEnterprise.Security.ActorContext{team_ids: ids}} ->
        ids

      %{id: id} when is_binary(id) ->
        AshEnterprise.Security.ActorContext.team_ids_for(id, ctx[:tenant])

      _nobody ->
        []
    end
  end

  # ── candidate clauses ────────────────────────────────────────────────────

  # The vocabulary is deliberately small. Every clause here is a fact this organization's
  # model can answer; anything else is a modelling question rather than a missing feature, and
  # an unknown clause is logged and contributes nobody rather than silently widening access.
  defp resolve_clause(%{"kind" => "user", "of" => path}, ctx) do
    case principal_from_path(path, ctx) do
      nil -> []
      id -> [%{type: :user, id: id}]
    end
  end

  defp resolve_clause(%{"kind" => "manager_of", "of" => path}, ctx) do
    with id when not is_nil(id) <- principal_from_path(path, ctx),
         %User{manager_id: manager_id} when not is_nil(manager_id) <- load_user(id, ctx) do
      [%{type: :user, id: manager_id}]
    else
      _ -> []
    end
  end

  defp resolve_clause(%{"kind" => "role"} = spec, ctx) do
    role_name = spec["of"] || spec["role"]

    UserRole
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(role.name == ^role_name)
    |> Ash.read!(read_opts(ctx))
    |> Enum.map(&%{type: :user, id: &1.user_id})
  rescue
    e ->
      Logger.warning("assignment resolver: role clause failed: #{Exception.message(e)}")
      []
  end

  defp resolve_clause(%{"kind" => "team", "of" => team_id}, _ctx) do
    [%{type: :team, id: team_id}]
  end

  defp resolve_clause(spec, _ctx) do
    Logger.warning("assignment resolver: unknown candidate clause #{inspect(spec)}; ignoring")
    []
  end

  # ── exclusions ───────────────────────────────────────────────────────────

  # Maker-checker. Applied by `ash_bpmn` as a subtraction from the candidate set, which is why
  # no deny rule ever reaches the policy engine.
  #
  # `"team_grantees"`: the people the subject hands a role to through a team -- every member
  # of the team a `TeamRole` assigns to, or of a `Team` restored. A review of such a grant is
  # offered to none of them, as a review of a person's own role is not offered to that person.
  # Any other subject has none.
  defp resolve_exclusion(%{"who" => "team_grantees"}, ctx) do
    case Map.get(ctx, :subject) do
      %AshEnterprise.Security.TeamRole{team_id: team_id} -> team_member_ids(team_id, ctx)
      %AshEnterprise.Accounts.Team{id: team_id} -> team_member_ids(team_id, ctx)
      _other -> []
    end
  end

  defp resolve_exclusion(%{"who" => path}, ctx) do
    case principal_from_path(path, ctx) do
      nil -> []
      id -> [id]
    end
  end

  defp resolve_exclusion(path, ctx) when is_binary(path) do
    resolve_exclusion(%{"who" => path}, ctx)
  end

  defp resolve_exclusion(spec, _ctx) do
    Logger.warning("assignment resolver: unknown exclusion #{inspect(spec)}; ignoring")
    []
  end

  # ── paths ────────────────────────────────────────────────────────────────

  # `"subject.created_by_id"`, `"instance.started_by_id"` and `"actor"` are the shapes a
  # diagram uses: the instance's `started_by_id` is the person whose write caused the event a
  # recipe started it from, which a review excludes so the granter cannot pass their own
  # change. Resolved by
  # walking the context rather than by evaluating an expression, because a candidate clause is
  # a reference to a person and not a computation -- and keeping it that way is what stops the
  # assignment vocabulary quietly becoming a second expression language.
  defp principal_from_path("actor", ctx), do: ctx |> Map.get(:actor) |> id_of()

  defp principal_from_path("subject." <> field, ctx) do
    case Map.get(ctx, :subject) do
      nil -> nil
      subject -> Map.get(subject, String.to_existing_atom(field))
    end
  rescue
    # An unknown field is a modelling error in the diagram, not a crash in the engine. It
    # resolves to nobody, and the task will have no candidate from this clause -- which is
    # visible immediately in the task list.
    ArgumentError -> nil
  end

  defp principal_from_path("instance." <> field, ctx) do
    case Map.get(ctx, :instance) do
      nil -> nil
      instance -> Map.get(instance, String.to_existing_atom(field))
    end
  rescue
    ArgumentError -> nil
  end

  defp principal_from_path(_other, _ctx), do: nil

  defp id_of(%{id: id}), do: id
  defp id_of(_), do: nil

  defp team_member_ids(nil, _ctx), do: []

  defp team_member_ids(team_id, ctx) do
    AshEnterprise.Accounts.TeamMembership
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(team_id == ^team_id)
    |> Ash.Query.select([:user_id])
    |> Ash.read!(read_opts(ctx))
    |> Enum.map(& &1.user_id)
  end

  defp load_user(id, ctx) do
    User
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(read_opts(ctx))
  rescue
    _ -> nil
  end

  # Reads run as the platform's system actor: resolving *who could approve this* is not
  # something the requester is entitled to do, and running it as them would silently produce a
  # shorter candidate list for a less privileged requester -- a task nobody can claim, with no
  # error anywhere.
  # Via `EngineContext` rather than `ctx[:tenant]`: the engine does not reliably supply it, and
  # a candidate query with no tenant returns nobody -- which presents as a task nobody can
  # claim rather than as a missing tenant.
  defp read_opts(ctx), do: AshEnterprise.Process.EngineContext.engine_opts(ctx)
end
