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

  It also stamps the write's tenant, which is what makes a per-tenant audit trail
  possible at all — `AshEnterprise.Audit.EventLog`'s chain trigger lifts it back
  out into a real, indexed `organization_id` column, and
  `AshEnterprise.Audit.Checks.OwnTenantTrail` filters on it.
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
      |> Map.merge(existing)

    Ash.Changeset.set_context(changeset, %{ash_events_metadata: metadata})
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
end
