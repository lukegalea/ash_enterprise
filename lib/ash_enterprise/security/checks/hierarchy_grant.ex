defmodule AshEnterprise.Security.Checks.HierarchyGrant do
  @moduledoc """
  Grant path 3: manager and position hierarchies.

  Authorizes when the record is owned by — or shared with — someone the actor sits
  above in the configured hierarchy.

  ## The direct/indirect asymmetry

  | Relationship | Verbs granted |
  |---|---|
  | Direct report | `:read`, `:write`, `:append`, `:append_to` |
  | Anyone further down the chain | `:read` only |

  Note what is absent from both rows: **`:delete`, `:assign` and `:share` are never
  granted by hierarchy.** Seniority lets you see and correct your reports' work; it
  does not let you destroy it or hand it to someone else. Those verbs require a
  role, which means they leave a trace in the role model that an auditor can find.

  ## The precondition

  Dataverse requires that a manager already hold *at least user-level Read* on a
  table before hierarchy grants anything on it. Hierarchy widens existing access
  along the org chart; it does not introduce access to tables you otherwise have
  no business reading.

  Without this, enabling hierarchy security would hand every manager visibility
  into tables they were never granted — payroll, audit, security configuration —
  purely because someone below them happens to own rows there. That is a
  privilege-escalation-by-configuration bug, so the precondition is enforced here
  rather than assumed.

  ## Disabled by default

  Returns `false` — contributing nothing to the union — unless
  `config :ash_enterprise, :hierarchy_security, mode: :manager | :position` is set.
  """

  use Ash.Policy.FilterCheck

  alias AshEnterprise.Security.AccessRight
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Security.Hierarchy

  @impl true
  def describe(_opts), do: "record belongs to someone the actor is above in the hierarchy"

  @impl true
  def filter(actor, authorizer, _opts) do
    context = ActorContext.for_actor(actor)
    hierarchy = context.hierarchy || %Hierarchy{}

    verb = AccessRight.for_action_type(authorizer.action.type)

    cond do
      hierarchy.mode == :disabled ->
        false

      is_nil(context.user_id) ->
        false

      # The precondition: hierarchy widens existing access, it never creates it.
      not has_baseline_read?(context, authorizer.resource) ->
        false

      true ->
        build_filter(hierarchy, verb, authorizer.resource)
    end
  end

  # "At least user-level Read" -- any read grant on this resource, at any depth.
  defp has_baseline_read?(context, resource) do
    grant = ActorContext.grant(context, resource, :read)

    grant.global? or grant.basic? or MapSet.size(grant.business_unit_ids) > 0
  end

  defp build_filter(hierarchy, verb, resource) do
    principal_ids =
      cond do
        verb in Hierarchy.direct_verbs() and verb in Hierarchy.indirect_verbs() ->
          # :read -- everyone below, at any depth.
          hierarchy.direct_principal_ids ++ hierarchy.indirect_principal_ids

        verb in Hierarchy.direct_verbs() ->
          # :write / :append / :append_to -- direct reports only.
          hierarchy.direct_principal_ids

        true ->
          # :delete, :assign, :share, :create -- never granted by hierarchy.
          []
      end

    shared_ids = shared_record_ids(hierarchy, verb, resource)

    [owner_clause(principal_ids, resource), shared_clause(shared_ids)]
    |> Enum.reject(&is_nil/1)
    |> combine()
  end

  defp shared_record_ids(hierarchy, verb, resource) do
    key = {inspect(resource), verb}

    direct = Map.get(hierarchy.direct_shared, key, MapSet.new())

    indirect =
      if verb in Hierarchy.indirect_verbs() do
        Map.get(hierarchy.indirect_shared, key, MapSet.new())
      else
        MapSet.new()
      end

    direct |> MapSet.union(indirect) |> MapSet.to_list()
  end

  defp owner_clause([], _resource), do: nil

  defp owner_clause(principal_ids, resource) do
    if Ash.Resource.Info.attribute(resource, :owner_id) do
      expr(owner_id in ^principal_ids)
    end
  end

  defp shared_clause([]), do: nil
  defp shared_clause(ids), do: expr(id in ^ids)

  defp combine([]), do: false
  defp combine([clause]), do: clause
  defp combine([a, b]), do: expr(^a or ^b)

  require Ash.Expr
  import Ash.Expr, only: [expr: 1]
end
