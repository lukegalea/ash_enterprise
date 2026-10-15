defmodule AshEnterprise.Canonical.Derive do
  @moduledoc """
  Derived facts: the first-class joins the canonical model concludes from the
  rows the projectors write (Luke, 2026-10-12: "we can start deriving info on
  top of the independent data and emitting new facts").

    * `attendees/3` — `AshEnterprise.Canonical.EventAttendee`: who an event's
      attendees are, and how each answered.
    * `participants/3` — `AshEnterprise.Canonical.ConversationParticipant`:
      who takes part in a conversation.

  Each reconciles the parent's join rows with the list it is given: rows for
  people still listed are upserted (a response can change), rows for people
  no longer listed are deleted. Both run inside the parent's upsert
  transaction (`AshEnterprise.Canonical.Changes.DeriveAttendees` /
  `DeriveParticipants`), so a projection writes a parent and its joins
  together or not at all, and a replay re-derives the same rows.

  Writes are the projection's, not a person's: `authorize?: false`, in the
  parent's tenant, owned by the parent's owner (insert-time, like every
  projected row). Errors are reduced to the resource and action, never the
  values (`AshEnterprise.Canonical.Projections.Write` explains why).

  `forget_scope/1` is the shred's half: every join row of the events and
  conversations sealed under one erasure scope.
  """

  require Ash.Query

  alias AshEnterprise.Canonical.{ConversationParticipant, EventAttendee}

  @responses %{
    "needsAction" => :needs_action,
    "accepted" => :accepted,
    "tentative" => :tentative,
    "declined" => :declined
  }

  @doc """
  Reconcile `event`'s attendees with `attendees`: maps carrying `person_id`
  (or `"person_id"`) and optionally `response_status` — an atom, or the
  provider's `responseStatus` string. Duplicates keep their first response.
  """
  @spec attendees(struct(), [map()], term()) :: :ok | {:error, term()}
  def attendees(event, attendees, tenant) do
    wanted =
      attendees
      |> Enum.flat_map(&attendee/1)
      |> Enum.uniq_by(& &1.person_id)

    reconcile(EventAttendee, :event_id, event, wanted, tenant)
  end

  @doc "Reconcile `conversation`'s participants with `person_ids`."
  @spec participants(struct(), [Ash.UUID.t()], term()) :: :ok | {:error, term()}
  def participants(conversation, person_ids, tenant) do
    wanted =
      person_ids
      |> Enum.flat_map(&uuid/1)
      |> Enum.uniq()
      |> Enum.map(&%{person_id: &1})

    reconcile(ConversationParticipant, :conversation_id, conversation, wanted, tenant)
  end

  @doc """
  Delete every join row whose parent (event or conversation) is sealed under
  `scope_id` — what a shred does to the derived facts, which hold ids rather
  than sealed values. Across tenants: a scope is not tenant-scoped.
  """
  @spec forget_scope(Ash.UUID.t()) :: :ok | {:error, term()}
  def forget_scope(scope_id) do
    with :ok <-
           forget(
             EventAttendee
             |> Ash.Query.filter(event.erasure_scope_id == ^scope_id)
           ) do
      forget(
        ConversationParticipant
        |> Ash.Query.filter(conversation.erasure_scope_id == ^scope_id)
      )
    end
  end

  # --- reconcile ---------------------------------------------------------------

  defp reconcile(resource, parent_key, parent, wanted, tenant) do
    keep = Enum.map(wanted, & &1.person_id)

    stale =
      resource
      |> Ash.Query.do_filter([{parent_key, parent.id}])
      |> Ash.Query.filter(person_id not in ^keep)
      |> Ash.Query.set_tenant(tenant)

    with :ok <- forget(stale) do
      write(resource, parent_key, parent, wanted, tenant)
    end
  end

  defp write(_resource, _parent_key, _parent, [], _tenant), do: :ok

  defp write(resource, parent_key, parent, wanted, tenant) do
    inputs = Enum.map(wanted, &Map.merge(&1, Map.put(owner(parent), parent_key, parent.id)))

    case Ash.bulk_create(inputs, resource, :derive,
           tenant: tenant,
           authorize?: false,
           return_errors?: true,
           stop_on_error?: true,
           return_records?: false
         ) do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{} -> {:error, {resource, :derive_failed}}
    end
  end

  defp forget(query) do
    case Ash.bulk_destroy(query, :forget, %{},
           authorize?: false,
           return_errors?: true,
           strategy: [:atomic, :stream]
         ) do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{} -> {:error, {query.resource, :forget_failed}}
    end
  end

  defp owner(parent) do
    %{
      owner_id: parent.owner_id,
      owner_type: parent.owner_type,
      owning_user_id: parent.owning_user_id,
      owning_business_unit_id: parent.owning_business_unit_id
    }
  end

  # --- inputs ------------------------------------------------------------------

  defp attendee(entry) when is_map(entry) do
    id = Map.get(entry, :person_id) || Map.get(entry, "person_id")
    status = Map.get(entry, :response_status) || Map.get(entry, "response_status")

    case uuid(id) do
      [person_id] -> [%{person_id: person_id, response_status: response(status)}]
      [] -> []
    end
  end

  defp attendee(_entry), do: []

  defp response(status) when status in [:needs_action, :accepted, :tentative, :declined],
    do: status

  defp response(status) when is_binary(status), do: Map.get(@responses, status)
  defp response(_status), do: nil

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> [id]
      :error -> []
    end
  end

  defp uuid(_value), do: []
end
