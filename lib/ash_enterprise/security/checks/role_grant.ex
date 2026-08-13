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

  ## Never queries

  Everything comes from the precomputed context. See
  `docs/manifesto/03-authorization-is-data.md` — a policy check that issues a
  query is a bug, not a slow path.
  """

  use Ash.Policy.FilterCheck

  alias AshEnterprise.Security.AccessRight
  alias AshEnterprise.Security.ActorContext

  @impl true
  def describe(_opts), do: "actor holds a role granting this action at sufficient depth"

  @impl true
  def filter(actor, authorizer, _opts) do
    context = ActorContext.for_actor(actor)

    cond do
      context.system? ->
        true

      is_nil(context.user_id) ->
        false

      true ->
        grant = ActorContext.grant(context, authorizer.resource, verb(authorizer))
        build_filter(grant, context, authorizer.resource)
    end
  end

  defp verb(authorizer) do
    AccessRight.for_action_type(authorizer.action.type)
  end

  defp build_filter(grant, context, resource) do
    cond do
      grant.global? ->
        true

      true ->
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
