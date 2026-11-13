defmodule AshEnterprise.Platform.Changes.StampCorrelation do
  @moduledoc """
  Puts the request's correlation id into the changeset context, where AshEvents
  picks it up as audit metadata.

  Applied by `AshEnterprise.Platform.Resource` to every audited resource, so the
  correlation is a property of being a platform resource rather than something
  each action remembers. See `AshEnterprise.Platform.Correlation` for why the
  grouping matters.

  Existing `ash_events_metadata` is merged rather than replaced: an action that
  attaches its own context keeps it, and gains the correlation alongside.

  A write made by a governed invocation's target also gets the invocation's key
  (`invocation_key`), from the action context the executor sets.

  A write a BPMN process step makes gets the step's instance trigger depth
  (`trigger_depth`), which the trigger sweep reads back to bound a process that writes
  the resource its own subscription watches. It comes from, in order: the `ash:call`
  context the engine sets (`context.ash_bpmn.trigger_depth`); the process scope
  `AshEnterprise.Process.ActionInvoker` opens around every service task
  (`Correlation.with_trigger_depth/2`); and, for a governed invocation executed later by
  another worker, the instance its `bpmn:<instance>:<token>:<node>` key names.

  It also stamps the write's tenant, which is what makes a per-tenant audit trail
  possible at all — `AshEnterprise.Audit.EventLog`'s chain trigger lifts it back
  out into a real, indexed `organization_id` column, and
  `AshEnterprise.Audit.Checks.OwnTenantTrail` filters on it. The tenant is stamped
  twice: when the changeset is built, and again in a `before_action` hook, because a
  write can be given its tenant only when it runs (`Ash.create!(changeset, tenant:
  tenant)`). The hook fills `organization_id` only when it is absent, so a value
  stamped earlier or supplied by the caller stands.
  The event log's lock key (`AshEvents.Chain.LockKeyGenerator`) is read from the same
  key after the hook, so the event locks the chain it joins. A write with no tenant at
  either point stays in the untenanted chain.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    existing =
      changeset.context
      |> Map.get(:ash_events_metadata, %{})
      |> normalize()

    metadata =
      AshEnterprise.Platform.Correlation.audit_metadata(context.actor)
      |> put_tenant(changeset.tenant)
      |> put_invocation(changeset.context)
      |> put_trigger_depth(changeset.context, changeset.tenant)
      |> Map.merge(existing)

    changeset
    |> Ash.Changeset.set_context(%{ash_events_metadata: metadata})
    |> Ash.Changeset.before_action(&stamp_run_tenant/1)
  end

  # The tenant the write runs under, when it was not known as the changeset was built.
  defp stamp_run_tenant(%{tenant: nil} = changeset), do: changeset

  defp stamp_run_tenant(changeset) do
    metadata = changeset.context |> Map.get(:ash_events_metadata, %{}) |> normalize()

    if Map.has_key?(metadata, "organization_id") do
      changeset
    else
      Ash.Changeset.set_context(changeset, %{
        ash_events_metadata: put_tenant(metadata, changeset.tenant)
      })
    end
  end

  defp normalize(map) when is_map(map), do: map
  defp normalize(_), do: %{}

  # The tenant of the write, which the audit log's chain trigger lifts back out
  # into a real `organization_id` column. Taken from the changeset rather than
  # from the actor: the changeset's tenant is what the row was actually written
  # under, and an actor acting across tenants (a system actor, an admin with a
  # global grant) would otherwise stamp the wrong one.
  defp put_tenant(metadata, nil), do: metadata
  defp put_tenant(metadata, tenant), do: Map.put(metadata, "organization_id", to_string(tenant))

  # A target run by a governed invocation (ADR 0055) carries the invocation's key in
  # its action context; the audit entry names it, so "this person, via this
  # invocation" is one row of the trail.
  defp put_invocation(metadata, %{ash_agent: %{invocation_key: key}}) when is_binary(key),
    do: Map.put(metadata, "invocation_key", key)

  defp put_invocation(metadata, _context), do: metadata

  defp put_trigger_depth(metadata, %{ash_bpmn: %{trigger_depth: depth}}, _tenant)
       when is_integer(depth),
       do: Map.put(metadata, "trigger_depth", depth)

  defp put_trigger_depth(%{"trigger_depth" => _} = metadata, _context, _tenant), do: metadata

  defp put_trigger_depth(
         metadata,
         %{ash_agent: %{invocation_key: "bpmn:" <> _ = key}},
         tenant
       ) do
    case AshEnterprise.Process.ServiceInvocation.trigger_depth(key, tenant) do
      depth when is_integer(depth) -> Map.put(metadata, "trigger_depth", depth)
      nil -> metadata
    end
  end

  defp put_trigger_depth(metadata, _context, _tenant), do: metadata

  # Temporal safety (AST-149, the earlier audit's judgment carried to the
  # SystemOne facts host): pure changeset-context plumbing — the
  # correlation id and tenant move into audit metadata; nothing reads the
  # clock, and the stamped context touches no row column.
  @impl true
  def temporal_safe?(_opts), do: true
end
