defmodule AshEnterprise.Integration.Outbound.Changes.FanOut do
  @moduledoc """
  One endpoint's fan-out, inside the `fan_out` update's transaction: read the tenant's audit
  events after the endpoint's cursor whose type the endpoint subscribes to, create one
  pending `AshEnterprise.Integration.Outbound.Delivery` for each (a redelivered event is a
  no-op on the `(endpoint_id, event_id)` identity), and advance the cursor.

  ## Why the cursor never skips an event

  Within one tenant's chain, `sequence` order is commit order
  (`AshEnterprise.Audit.EventLog`, "Something depends on that lock"). The tenant's
  high-water mark is read first; the events are then read up to it. Every event at or below
  it had committed when it was read, and every event committed later has a higher
  sequence, so moving the cursor to the high-water mark (or, when a page is full, to the
  last event read) passes nothing that was not seen.

  ## Behind retention

  Events older than ninety days leave the hot log for the archive. If the tenant has an
  archived event after the cursor, the endpoint lagged past the hot window and would miss
  events silently, so it is set `failing` with `status_reason` `"cursor_behind_retention"`
  instead, and nothing is created.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Audit.{ArchivedEvent, EventLog, EventSource}
  alias AshEnterprise.Integration.Outbound.{Catalogue, Delivery}
  alias AshEnterprise.Platform.SystemActor

  @page 500

  # The page size; tests set `config :ash_enterprise, AshEnterprise.Integration.Outbound.Changes.FanOut, page: n`.
  defp page_size,
    do: Keyword.get(Application.get_env(:ash_enterprise, __MODULE__, []), :page, @page)

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &fan_out/1)
  end

  defp fan_out(changeset) do
    endpoint = changeset.data
    tenant = endpoint.organization_id
    cursor = Ash.Changeset.get_attribute(changeset, :cursor_sequence)
    high_water = EventSource.latest_sequence(tenant)

    cond do
      high_water <= cursor ->
        changeset

      behind_retention?(tenant, cursor) ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :failing)
        |> Ash.Changeset.force_change_attribute(:status_reason, "cursor_behind_retention")

      true ->
        page = page(endpoint, cursor, tenant, high_water)
        enqueue!(endpoint, tenant, Enum.flat_map(page, &subscribed(&1, endpoint.event_types)))

        # A full page may stop short of the mark: the cursor moves to the last event read
        # (subscribed or not), and the next minute reads on from there.
        cursor =
          if length(page) == page_size(), do: List.last(page).sequence, else: high_water

        Ash.Changeset.force_change_attribute(changeset, :cursor_sequence, cursor)
    end
  end

  # One page of the tenant's events after the cursor, of the resources the endpoint's types
  # name, before the action types are matched.
  defp page(endpoint, cursor, tenant, high_water) do
    entries = Catalogue.for_types(endpoint.event_types)
    resources = entries |> Enum.map(& &1.resource) |> Enum.uniq()

    EventLog
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      sequence > ^cursor and sequence <= ^high_water and
        resource in ^resources and action_type in [:create, :update, :destroy]
    )
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.Query.limit(page_size())
    |> Ash.read!(actor: SystemActor.oban(), tenant: tenant)
  end

  # The event with its catalogue type, when the endpoint subscribes to that type.
  defp subscribed(event, event_types) do
    type = Catalogue.type_of(event.resource, event.action_type)

    if is_binary(type) and type in event_types,
      do: [Map.put(event, :__type__, type)],
      else: []
  end

  defp enqueue!(_endpoint, _tenant, []), do: :ok

  defp enqueue!(endpoint, tenant, events) do
    inputs =
      for event <- events do
        %{
          endpoint_id: endpoint.id,
          event_id: event.id,
          event_sequence: event.sequence,
          event_type: event.__type__,
          subject_id: to_string(event.record_id),
          occurred_at: event.occurred_at
        }
      end

    %Ash.BulkResult{status: :success} =
      Ash.bulk_create(inputs, Delivery, :enqueue,
        actor: SystemActor.oban(),
        tenant: tenant,
        upsert?: true,
        upsert_identity: :unique_event,
        upsert_fields: [],
        return_errors?: true,
        stop_on_error?: true
      )

    :ok
  end

  defp behind_retention?(tenant, cursor) do
    ArchivedEvent
    |> Ash.Query.filter(organization_id == ^tenant and sequence > ^cursor)
    |> Ash.exists?(authorize?: false, tenant: tenant)
  end
end
