defmodule AshEnterprise.Mdm.PersonJoins do
  @moduledoc """
  What a person merge moves besides identities (PROD-9): the rows that name
  the absorbed person, so their meetings, messages and conversations follow
  them to the golden record — and exactly those rows back on the unmerge.

    * `EventAttendee.person` and `ConversationParticipant.person` — the
      derived joins. A join the survivor already has (both addresses invited
      to one meeting) cannot move, since the pair is unique; it is dropped,
      and recorded with its answer so the unmerge can re-derive it.
    * `Message.sender` and `CalendarEvent.organizer`.
    * Records the loser absorbed earlier (`master_id`), so a master is always
      a golden record.

  `plan/3` reads the row ids before the merge writes anything, and the plan
  rides on the loser's `merge_provenance` (ids only — no names, no
  addresses, nothing sealed). `apply!/3` moves them; `restore!/3` moves them
  back. Rows a projector writes *after* the merge already name the golden
  (`AshEnterprise.Canonical.Projections.Golden`); after an unmerge they are
  re-derived by the next projection of their source
  (`mix ash_enterprise.integration.project`), not by the unmerge.

  Machinery: every read and write here is `authorize?: false` inside the
  merge's own transaction, which is the authorized act.
  """

  require Ash.Query

  alias AshEnterprise.Canonical.{
    CalendarEvent,
    ConversationParticipant,
    EventAttendee,
    Message,
    Person
  }

  @doc "The rows that name `loser_id`, and which of its joins `survivor_id` already has."
  @spec plan(term(), Ash.UUID.t(), Ash.UUID.t()) :: map()
  def plan(tenant, loser_id, survivor_id) do
    %{
      "attendances" => joins(EventAttendee, :event_id, tenant, loser_id, survivor_id),
      "participations" =>
        joins(ConversationParticipant, :conversation_id, tenant, loser_id, survivor_id),
      "sent_message_ids" => ids(Message, [sender_id: loser_id], tenant),
      "organized_event_ids" => ids(CalendarEvent, [organizer_id: loser_id], tenant),
      "absorbed_ids" => ids(Person, [master_id: loser_id], tenant)
    }
  end

  @doc "Moves the planned rows to `survivor_id`."
  @spec apply!(term(), map() | nil, Ash.UUID.t()) :: :ok
  def apply!(_tenant, nil, _survivor_id), do: :ok

  def apply!(tenant, plan, survivor_id) do
    move(EventAttendee, moved(plan, "attendances"), %{person_id: survivor_id}, tenant)
    forget(EventAttendee, dropped_ids(plan, "attendances"), tenant)

    move(
      ConversationParticipant,
      moved(plan, "participations"),
      %{person_id: survivor_id},
      tenant
    )

    forget(ConversationParticipant, dropped_ids(plan, "participations"), tenant)
    move(Message, plan["sent_message_ids"], %{sender_id: survivor_id}, tenant)
    move(CalendarEvent, plan["organized_event_ids"], %{organizer_id: survivor_id}, tenant)
    move(Person, plan["absorbed_ids"], %{master_id: survivor_id}, tenant, :mdm_repoint_master)
    :ok
  end

  @doc "Moves the planned rows back to `loser_id`, re-deriving the joins the merge dropped."
  @spec restore!(term(), map() | nil, Ash.UUID.t()) :: :ok
  def restore!(_tenant, nil, _loser_id), do: :ok

  def restore!(tenant, plan, loser_id) do
    move(EventAttendee, moved(plan, "attendances"), %{person_id: loser_id}, tenant)
    move(ConversationParticipant, moved(plan, "participations"), %{person_id: loser_id}, tenant)

    rederive(
      EventAttendee,
      CalendarEvent,
      :event_id,
      dropped(plan, "attendances"),
      loser_id,
      tenant
    )

    rederive(
      ConversationParticipant,
      AshEnterprise.Canonical.Conversation,
      :conversation_id,
      dropped(plan, "participations"),
      loser_id,
      tenant
    )

    move(Message, plan["sent_message_ids"], %{sender_id: loser_id}, tenant)
    move(CalendarEvent, plan["organized_event_ids"], %{organizer_id: loser_id}, tenant)
    move(Person, plan["absorbed_ids"], %{master_id: loser_id}, tenant, :mdm_repoint_master)
    :ok
  end

  # --- reading -------------------------------------------------------------------

  defp joins(resource, parent_key, tenant, loser_id, survivor_id) do
    rows =
      resource
      |> Ash.Query.filter(person_id == ^loser_id)
      |> Ash.Query.select(join_fields(resource, parent_key))
      |> Ash.read!(tenant: tenant, authorize?: false)

    parents = Enum.map(rows, &Map.fetch!(&1, parent_key))

    survivor_has =
      resource
      |> Ash.Query.filter(person_id == ^survivor_id)
      |> Ash.Query.do_filter([{parent_key, [in: parents]}])
      |> Ash.Query.select([parent_key])
      |> Ash.read!(tenant: tenant, authorize?: false)
      |> MapSet.new(&Map.fetch!(&1, parent_key))

    {dropped, moved} =
      Enum.split_with(rows, &MapSet.member?(survivor_has, Map.fetch!(&1, parent_key)))

    %{
      "moved" => moved |> Enum.map(& &1.id) |> Enum.sort(),
      "dropped" =>
        dropped
        |> Enum.map(&dropped_entry(&1, parent_key))
        |> Enum.sort_by(& &1["id"])
    }
  end

  defp join_fields(EventAttendee, parent_key), do: [:id, parent_key, :response_status]
  defp join_fields(_resource, parent_key), do: [:id, parent_key]

  defp dropped_entry(row, parent_key) do
    %{"id" => row.id, "parent_id" => Map.fetch!(row, parent_key)}
    |> then(fn entry ->
      case Map.get(row, :response_status) do
        nil -> entry
        status -> Map.put(entry, "response_status", Atom.to_string(status))
      end
    end)
  end

  defp ids(resource, filter, tenant) do
    resource
    |> Ash.Query.do_filter(filter)
    |> Ash.Query.select([:id])
    |> Ash.read!(tenant: tenant, authorize?: false)
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp moved(plan, key), do: get_in(plan, [key, "moved"]) || []
  defp dropped(plan, key), do: get_in(plan, [key, "dropped"]) || []
  defp dropped_ids(plan, key), do: Enum.map(dropped(plan, key), & &1["id"])

  # --- writing -------------------------------------------------------------------

  defp move(resource, ids, input, tenant, action \\ :mdm_repoint)
  defp move(_resource, nil, _input, _tenant, _action), do: :ok
  defp move(_resource, [], _input, _tenant, _action), do: :ok

  defp move(resource, ids, input, tenant, action) do
    resource
    |> Ash.Query.filter(id in ^ids)
    |> Ash.bulk_update!(action, input,
      tenant: tenant,
      authorize?: false,
      strategy: [:atomic, :stream],
      return_errors?: true
    )

    :ok
  end

  defp forget(_resource, [], _tenant), do: :ok

  defp forget(resource, ids, tenant) do
    resource
    |> Ash.Query.filter(id in ^ids)
    |> Ash.bulk_destroy!(:forget, %{},
      tenant: tenant,
      authorize?: false,
      strategy: [:atomic, :stream],
      return_errors?: true
    )

    :ok
  end

  # A dropped join comes back as the derive writes it: the parent's owner,
  # the loser's id, the answer it had.
  defp rederive(_resource, _parent_resource, _parent_key, [], _loser_id, _tenant), do: :ok

  defp rederive(resource, parent_resource, parent_key, entries, loser_id, tenant) do
    parents =
      parent_resource
      |> Ash.Query.filter(id in ^Enum.map(entries, & &1["parent_id"]))
      |> Ash.Query.select([
        :id,
        :owner_id,
        :owner_type,
        :owning_user_id,
        :owning_business_unit_id
      ])
      |> Ash.read!(tenant: tenant, authorize?: false)
      |> Map.new(&{&1.id, &1})

    inputs =
      for entry <- entries, parent = parents[entry["parent_id"]] do
        %{
          parent_key => parent.id,
          :person_id => loser_id,
          :owner_id => parent.owner_id,
          :owner_type => parent.owner_type,
          :owning_user_id => parent.owning_user_id,
          :owning_business_unit_id => parent.owning_business_unit_id
        }
        |> maybe_response(entry["response_status"])
      end

    Ash.bulk_create!(inputs, resource, :derive,
      tenant: tenant,
      authorize?: false,
      return_errors?: true,
      return_records?: false
    )

    :ok
  end

  @responses Map.new([:needs_action, :accepted, :tentative, :declined], &{Atom.to_string(&1), &1})

  defp maybe_response(input, status) do
    case Map.fetch(@responses, status) do
      {:ok, response} -> Map.put(input, :response_status, response)
      :error -> input
    end
  end
end
