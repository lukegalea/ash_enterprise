defmodule AshEnterprise.Security.Checks.RoleGrant do
  @moduledoc """
  Grant path 1: `(role, privilege, depth)`.

  Authorizes when the actor holds a role granting the verb this action needs, at
  a depth that reaches this record. Depth resolution:

  | Depth | Reaches |
  |---|---|
  | `:global` | everything — the filter is simply `true` |
  | `:deep` / `:local` | `owning_business_unit_id ∈` the precomputed id set |
  | `:basic` | `owner_id` is the actor, or one of the actor's teams |

  `:deep` and `:local` collapse into one id set in
  `AshEnterprise.Security.ActorContext`, so by the time this runs there is no
  hierarchy to walk.

  ## A filter check, not a simple check

  Implemented as `Ash.Policy.FilterCheck` so **reads narrow instead of failing**.
  A user listing teams gets the teams they can see, not a 403 — which is both
  better behaviour and better security, since a forbidden error confirms that a
  record exists.

  Ash applies the same filter as a predicate for writes, so one implementation
  covers create, read, update and destroy.

  ## A grant read off another resource

  `{RoleGrant, as: Resource}` answers from the actor's grant on `Resource` rather than
  on the resource the policy belongs to. It is for a resource that is another one's
  rows moved elsewhere, where a separate privilege would be a second grant over the same
  data: `AshEnterprise.Audit.ArchivedEvent` is the audit log past ninety days, so reading
  it is reading `AshEnterprise.Audit.EventLog`. The depth clauses still test the policy's
  own resource's columns.

  ## A grant on one column

  `{RoleGrant, field: :number}` answers from the actor's `:read` grant on the column's own
  privilege, `"<Resource>#number"`, whatever action is running: it is the check the base
  resource writes into a field policy for each of its `secured_fields`
  (`AshEnterprise.Platform.Resource`). The verb is fixed because a field grant is a grant
  to see the value, and Ash evaluates field policies on the records a create or update
  returns too; a `:write` grant on the column does not exist. The depth clauses test the
  policy's own resource's columns, so a field grant at `:local` reveals the column on the
  rows in that business unit and leaves it hidden on the rest.

  ## Never queries

  Everything comes from the precomputed context. See
  `docs/manifesto/03-authorization-is-data.md` — a policy check that issues a
  query is a bug, not a slow path.
  """

  use Ash.Policy.FilterCheck

  alias AshEnterprise.Security.AccessRight
  alias AshEnterprise.Security.ActorContext

  @impl true
  def describe(opts) do
    cond do
      field = Keyword.get(opts, :field) ->
        "actor holds a role granting read on the #{field} column at sufficient depth"

      resource = Keyword.get(opts, :as) ->
        "actor holds a role granting this action on #{inspect(resource)}"

      true ->
        "actor holds a role granting this action at sufficient depth"
    end
  end

  @doc """
  The privilege key of `field` on `resource`: `"<inspect(resource)>#<field>"`. The
  privilege catalogue writes one `:read` privilege under it for each secured field
  (`AshEnterprise.Platform.Seeder`).
  """
  @spec field_key(module(), atom()) :: String.t()
  def field_key(resource, field), do: "#{inspect(resource)}##{field}"

  @impl true
  def filter(actor, authorizer, opts) do
    context = ActorContext.for_actor(actor)
    field = Keyword.get(opts, :field)

    granted_on =
      if field,
        do: field_key(authorizer.resource, field),
        else: Keyword.get(opts, :as) || authorizer.resource

    verb = if field, do: :read, else: verb(authorizer)

    cond do
      # A system actor is not subject to grants, but it reaches no further here
      # than through its own bypass: not a `human_only` action, and a
      # `machinery_only` one only as `oban` (ADR 0059). Without this the union
      # would hand back what the narrowed bypass withheld.
      context.system? ->
        AshEnterprise.Security.ActionReach.system_actor?(
          actor,
          authorizer.resource,
          authorizer.action
        )

      is_nil(context.user_id) ->
        false

      generic?(authorizer) ->
        ActorContext.grant(context, granted_on, verb).global?

      true ->
        grant = ActorContext.grant(context, granted_on, verb)
        build_filter(grant, context, authorizer.resource)
    end
  end

  # A generic action has no row for a depth to reach, and Ash refuses to
  # evaluate a filter for one (it raises rather than forbidding). So only a
  # grant that reaches every row -- `:global` -- authorizes it; a narrower one
  # contributes `false`. This is the answer the raise already enforced, made
  # a clean refusal that `Ash.can?/3` (the ACP palette's pruning) can report.
  defp generic?(%{action: %{type: :action}}), do: true
  defp generic?(_authorizer), do: false

  defp verb(authorizer) do
    AccessRight.for_action_type(authorizer.action.type)
  end

  defp build_filter(grant, context, resource) do
    if grant.global? do
      true
    else
      [business_unit_clause(grant, resource), basic_clause(grant, context, resource)]
      |> Enum.reject(&is_nil/1)
      |> combine()
    end
  end

  # Depth :local / :deep -- the record's owning business unit is in reach.
  defp business_unit_clause(grant, resource) do
    ids = MapSet.to_list(grant.business_unit_ids)

    cond do
      ids == [] -> nil
      not has_attribute?(resource, :owning_business_unit_id) -> nil
      true -> expr(owning_business_unit_id in ^ids)
    end
  end

  # Depth :basic -- I own it, or one of my teams does.
  #
  # Only meaningful for :user_owned resources. A :business_owned resource has no
  # owner_id at all, which is exactly why Privilege refuses to grant :basic on
  # one (see Privilege.legal_depths/1).
  defp basic_clause(grant, context, resource) do
    cond do
      not grant.basic? ->
        nil

      not has_attribute?(resource, :owner_id) ->
        nil

      context.team_ids == [] ->
        expr(owner_id == ^context.user_id)

      true ->
        principal_ids = [context.user_id | context.team_ids]
        expr(owner_id in ^principal_ids)
    end
  end

  defp combine([]), do: false
  defp combine([clause]), do: clause
  defp combine([a, b]), do: expr(^a or ^b)

  defp has_attribute?(resource, name) do
    not is_nil(Ash.Resource.Info.attribute(resource, name))
  end

  require Ash.Expr
  import Ash.Expr, only: [expr: 1]
end
