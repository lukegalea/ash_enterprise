defmodule AshEnterprise.Surfaces.Doors do
  @moduledoc """
  The doors in front of registry surfaces (`AshEnterprise.Surfaces`), one
  predicate per door, enforced by both transports: the web
  (`AshEnterpriseWeb.SurfaceDoor`, on mount) and ACP
  (`AshEnterprise.Acp.Commands`, before a route is returned, and again in
  `Console.open`).

  A door decides nothing the policies do not. Behind it every surface still
  reads as the actor; the door exists so a person without the grant is told
  so, instead of looking at an empty table — and, for the compliance
  surfaces, because the foreign `ash_compliance` resources cannot carry this
  application's policy block (ADR 0035), so the door *is* where the grant
  those policies would check gets checked.

    * `:signed_in` — any actor.
    * `:operator` — a read grant on erasure scopes, whose privileges are
      reserved to the Platform Operator
      (`AshEnterprise.Security.Privilege.operator_only?/1`).
    * `:compliance` — a read grant on `AshCompliance.Resources.Finding`, the
      exact `(role, privilege, depth)` tuple the derived catalogue creates and
      the seeded Administrator role picks up.
    * `:lineage` — a read grant on `AshEnterprise.Lineage.Run`: every
      Administrator, and any role given it as a grant row.
    * `:audit` — a read grant on `AshEnterprise.Audit.EventLog`.

  Reads the actor's precomputed `ActorContext` (attached once per request or
  ACP session); `ActorContext.for_actor/1` only builds one for an actor that
  arrives without it.
  """

  alias AshEnterprise.Security.ActorContext

  @gates %{
    operator: AshEnterprise.Erasure.Scope,
    compliance: AshCompliance.Resources.Finding,
    lineage: AshEnterprise.Lineage.Run,
    audit: AshEnterprise.Audit.EventLog
  }

  @doc "Whether `door` is open for `actor`."
  @spec open?(AshEnterprise.Surfaces.Surface.door(), term()) :: boolean()
  def open?(_door, nil), do: false
  def open?(:signed_in, _actor), do: true

  def open?(door, actor) when is_map_key(@gates, door) do
    context = ActorContext.for_actor(actor)
    grant = ActorContext.grant(context, Map.fetch!(@gates, door), :read)

    context.system? or grant.global? or grant.basic? or MapSet.size(grant.business_unit_ids) > 0
  end

  def open?(_unknown, _actor), do: false

  @doc "Who a door admits, as the end of a sentence (`\"… is for <audience>.\"`)."
  @spec audience(AshEnterprise.Surfaces.Surface.door()) :: String.t()
  def audience(:operator), do: "the platform operator"
  def audience(:compliance), do: "people with a compliance grant"
  def audience(:lineage), do: "people with a lineage grant"
  def audience(:audit), do: "people with an audit grant"
  def audience(_door), do: "signed-in people"
end
