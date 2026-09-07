defmodule AshEnterprise.Audit.EventSource do
  @moduledoc """
  The `AshBpmn.EventSource` adapter over `AshEnterprise.Audit.EventLog` — the one
  module that couples the bpmn trigger engine to this application's audit chain.

  The engine never sees `ash_events` types; everything it knows about the log it
  learns through the six callbacks here. Configured in `config/config.exs`:

      config :ash_bpmn, event_source: AshEnterprise.Audit.EventSource

  ## The event context is a published contract

  `c:context/1` builds the map every guard, subject expression and correlation
  key evaluates against. Changing its shape breaks every tenant's subscriptions,
  so it is a contract rather than an internal detail (ported verbatim from the
  prototype's `Process.Triggers.Dispatch.context_for/1`):

      %{
        "event" => %{"id", "sequence", "occurred_at", "resource", "action",
                     "action_type", "record_id", "version"},
        "actor" => %{"user_id", "system_actor", "impersonator_id"},
        "tenant" => %{"organization_id"},
        "data" => %{...},      # the record as written — a snapshot, not a live read
        "changed" => %{...},
        "metadata" => %{...}   # correlation_id, depth, ...
      }

  `data` is the event's snapshot, not a live read: by sweep time the record may
  have changed or been archived. A trigger fires on what happened, so a guard
  must never be written as if it were a query, and the process it starts
  re-reads its subject through Ash.

  ### The three spellings of a resource name

  | Where | Form |
  |---|---|
  | The `audit_events` column | `"Elixir.AshEnterprise.Security.Role"` |
  | `event.resource` as Ash returns it | the module **atom**, cast back on read |
  | The event context a guard sees | `"AshEnterprise.Security.Role"` |

  The short form is chosen for the third because it is what a person types and
  what a FEEL guard compares against. The spelling logic from the prototype's
  `Process.Trigger.ResourceName` (deleted with the rest of the trigger
  prototype) lives here now; the library's
  `AshBpmn.Resources.Subscription.ResourceName` does the same job for the
  subscription side, and both sides normalizing to one short form is what keeps
  the sweep's match a plain string comparison.

  ## The ordering guarantee, and exactly how far it reaches

  `c:order_guarantee/1` is a **declaration, not a measurement**. Returning
  `:commit_order` for a real tenant claims that within that tenant, `sequence`
  order equals commit order.

  That claim is an **implementation detail inherited from `ash_events`' write
  path**: `AshEvents` takes a per-tenant `pg_advisory_xact_lock` immediately
  before inserting the event row, inside the audited action's own transaction,
  and `xact` scope holds it until `COMMIT` — so a second transaction for the
  same tenant cannot consume `nextval()` until the first has committed. It is
  not a contract `ash_events` makes, and an upstream change (or configuring a
  custom `advisory_lock_key_generator`) would invalidate it silently. The
  property was measured rather than assumed; the measurements, its limits, and
  the design resting on them are in
  `docs/plans/event-triggered-processes.md` §2, and `AshEnterprise.Audit.EventLog`'s
  moduledoc records the same dependency beside the chain it also supports.

  The `organization_id IS NULL` chain — where the writes of `tenant?: false`
  resources land — shares **no lock space** with anything: the default key
  generator produces a two-element key under attribute multitenancy and a
  single integer otherwise, and Postgres treats those as separate lock spaces.
  It is therefore `:best_effort`, full stop: it has no ordering guarantee to
  weaken. It also gets no sweep fan-out — `trigger_tenants/0` enumerates real
  organizations only, and a cursor row for a NULL tenant is impossible under
  the platform base's `allow_nil? false` tenancy invariant.

  ## Not a change feed

  `c:audited?/1` answers whether `resource` writes **into this log**. The log is
  a feed of writes that went through an audited Ash action, not of every change
  to a row: raw SQL produces no event, and a subscription watching one waits
  forever without erroring — which is why publish-time refusals call this with
  the resource named rather than letting the silence stand.
  """

  @behaviour AshBpmn.EventSource

  require Ash.Query

  alias AshEnterprise.Platform.SystemActor

  @impl true
  def stream(tenant, after_sequence, limit) do
    query =
      AshEnterprise.Audit.EventLog
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(sequence > ^after_sequence)
      |> Ash.Query.sort(sequence: :asc)
      |> Ash.Query.limit(limit)
      # The NULL-tenant chain is its own chain. Without this, a `nil` tenant
      # read — legal, because the log's multitenancy is `global? true` so a
      # cross-tenant investigation can see everything — would stream every
      # tenant's events as one chain, which is exactly the global cursor the
      # design refuses.
      |> maybe_null_chain(is_nil(tenant))

    events = Ash.read!(query, actor: SystemActor.process(), tenant: tenant)

    {:ok, {events, last_sequence(events)}}
  end

  defp maybe_null_chain(query, true), do: Ash.Query.filter(query, is_nil(organization_id))
  defp maybe_null_chain(query, false), do: query

  # Ported from the prototype's `Process.Triggers.Dispatch.context_for/1`.
  # The shape is a published contract — see the moduledoc — and `data` is
  # deliberately the event's snapshot, not a live read.
  @impl true
  def context(event) do
    %{
      "event" => %{
        "id" => event.id,
        "sequence" => event.sequence,
        "occurred_at" => event.occurred_at,
        # The short name, so a guard reads
        # `event.resource = "AshEnterprise.Security.Role"` rather than carrying
        # the `Elixir.` prefix into a business rule.
        "resource" => resource_name(event.resource),
        "action" => to_string(event.action),
        "action_type" => to_string(event.action_type),
        "record_id" => event.record_id,
        "version" => event.version
      },
      "actor" => %{
        "user_id" => event.user_id,
        "system_actor" => get_in(event.metadata || %{}, ["system_actor"]),
        "impersonator_id" => get_in(event.metadata || %{}, ["impersonator_id"])
      },
      "tenant" => %{"organization_id" => event.organization_id},
      "data" => event.data || %{},
      "changed" => Map.get(event, :changed_attributes) || %{},
      "metadata" => event.metadata || %{}
    }
  end

  @impl true
  def sequence(event), do: event.sequence

  @impl true
  def occurred_at(event), do: event.occurred_at

  # A declaration, not a measurement — see the moduledoc for the property being
  # claimed, where it was measured, and why the NULL chain claims nothing.
  @impl true
  def order_guarantee(nil), do: :best_effort
  def order_guarantee(_tenant), do: :commit_order

  @impl true
  def audited?(resource) do
    AshEvents.Events in Ash.Resource.Info.extensions(resource) and
      match?(
        {:ok, AshEnterprise.Audit.EventLog},
        AshEvents.Events.Info.events_event_log(resource)
      )
  rescue
    # Not an Ash resource, or not an auditable one: either way it writes no
    # events into this log, which is the question being asked.
    _ -> false
  end

  ## The resource-name spellings, ported from Process.Trigger.ResourceName.

  # `event.resource` is a module atom — Ash casts the column back on read — so
  # every comparison against a stored `match_resource` goes through this.
  defp resource_name(resource) when is_atom(resource), do: inspect(resource)
  defp resource_name(resource) when is_binary(resource), do: short_name(resource)

  defp short_name(name) when is_binary(name),
    do: String.replace_prefix(name, "Elixir.", "")

  defp last_sequence([]), do: nil
  defp last_sequence(events), do: List.last(events).sequence
end
