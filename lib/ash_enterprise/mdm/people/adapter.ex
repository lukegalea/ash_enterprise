defmodule AshEnterprise.Mdm.People.Adapter do
  @moduledoc """
  The adapter for the `:canonical` source in `AshEnterprise.Mdm.Landing`
  (PROD-9): turns the people the Gmail, Calendar and Slack projectors
  produced into raw observations for MDM's land action.

  One observation per person per source it was seen in — a source being the
  projector's `external_system` and the linked account its rows were sealed
  under (the erasure scope of kind `:connection` names the account). Seen in
  means: attending or organizing one of that source's calendar events, or
  taking part in one of its conversations. The payload is the person as the
  canonical store has it, never more:

      %{"person_id" => ..., "name" => ..., "email" => ...,
        "system" => "gmail", "linked_account_id" => ...}

  The person's identity in MDM is the observation's external id,
  `"org:people:<person_id>:<system>:<linked_account_id>"` — so the Slack and
  the Calendar sighting of one address are two source identities pointing at
  one golden, and the Gmail sighting of the same human's other address is a
  third, until a steward says otherwise.

  Push-shaped like the CSV source: the people sweep lands these rows per
  tenant (`land/2`); there is nothing for a bizev sync to pull, so
  `fetch_batch/5` returns an error rather than an empty page, and a sync
  accidentally pointed here fails visibly. A merged person is not observed:
  its rows moved to its golden with the merge.

  Also exposes the co-occurrence evidence the people matcher reads
  (`evidence/1`): which events and conversations each person is in.
  """

  @behaviour AshDiscreteBusinessEvents.Adapters.Adapter

  require Ash.Query

  alias AshEnterprise.Canonical.{
    CalendarEvent,
    Conversation,
    ConversationParticipant,
    EventAttendee,
    Person
  }

  alias AshEnterprise.Mdm.People

  @impl true
  def cursor_field(_stream), do: "fetched_at"

  @impl true
  def fetch_batch(_source, _stream, _conn, _cursor, _opts),
    do: {:error, :push_only_source}

  @impl true
  def api_calls_per_batch, do: 1

  @typedoc "Which events and conversations each person is in, by context key."
  @type evidence :: %{
          contexts: %{Ash.UUID.t() => MapSet.t()},
          members: %{term() => MapSet.t()}
        }

  @doc """
  The tenant's observations (`%{row_key:, payload:}`, sorted by row key) and
  the co-occurrence evidence they were derived from.
  """
  @spec observe(term()) :: {[map()], evidence()}
  def observe(tenant) do
    people =
      Person
      |> Ash.Query.filter(merged == false and not is_nil(email))
      |> Ash.Query.select([:id, :name, :email])
      |> Ash.read!(tenant: tenant, authorize?: false)

    ids = Enum.map(people, & &1.id)

    sightings = event_sightings(tenant, ids) ++ conversation_sightings(tenant, ids)
    accounts = accounts(sightings)

    by_person = Enum.group_by(sightings, & &1.person_id)

    observations =
      people
      |> Enum.flat_map(fn person ->
        by_person
        |> Map.get(person.id, [])
        |> Enum.map(&{&1.system, accounts[&1.scope_id]})
        |> Enum.uniq()
        |> Enum.map(fn {system, account_id} ->
          %{
            row_key: "#{person.id}:#{system}:#{account_id || "none"}",
            payload: payload(person, system, account_id)
          }
        end)
      end)
      |> Enum.sort_by(& &1.row_key)

    {observations, evidence(sightings)}
  end

  @doc """
  The observation payload for `person` — also how the matcher puts a golden
  through the same mapping as the staged side, so one mapping normalizes
  both.
  """
  def payload(person, system \\ nil, account_id \\ nil) do
    %{
      "person_id" => person.id,
      "name" => person.name,
      "email" => person.email && to_string(person.email),
      "system" => system,
      "linked_account_id" => account_id
    }
  end

  @doc """
  Lands `observations` for `tenant` on the `:canonical`/`:people` stream.
  Returns how many opened a new period (an identical re-observation is
  bizev's temporal no-op).
  """
  @spec land!(term(), [map()]) :: non_neg_integer()
  def land!(tenant, observations) do
    started_at = DateTime.utc_now()

    # The tenant's zone decides the region, as for the CSV upload
    # (`AshEnterprise.Mdm.Landing.land_row/4`).
    region =
      :ash_enterprise
      |> Application.get_env(AshEnterprise.Mdm.Landing, [])
      |> Keyword.get(:default_region, :us)

    Enum.count(observations, fn %{row_key: row_key, payload: payload} ->
      {:ok, record} =
        AshEnterprise.Mdm.SourceRecord.land(
          %{
            source: People.source(),
            stream: People.stream(),
            external_id: "#{tenant}:#{People.slug()}:#{row_key}",
            region: region,
            residency_tag: Atom.to_string(region),
            raw_payload: payload,
            source_metadata: %{"tenant" => tenant, "slug" => People.slug()},
            cursor: nil,
            fetched_at: started_at
          },
          tenant: tenant,
          authorize?: false
        )

      DateTime.compare(record.recorded_at, started_at) != :lt
    end)
  end

  # --- sightings -------------------------------------------------------------------

  defp event_sightings(_tenant, []), do: []

  defp event_sightings(tenant, ids) do
    attendances =
      EventAttendee
      |> Ash.Query.filter(person_id in ^ids)
      |> Ash.Query.select([:person_id, :event_id])
      |> Ash.read!(tenant: tenant, authorize?: false)

    organized =
      CalendarEvent
      |> Ash.Query.filter(organizer_id in ^ids)
      |> Ash.Query.select([:id, :organizer_id])
      |> Ash.read!(tenant: tenant, authorize?: false)
      |> Enum.map(&%{person_id: &1.organizer_id, event_id: &1.id})

    links = attendances ++ organized
    events = parents(CalendarEvent, Enum.map(links, & &1.event_id), tenant)

    for link <- links, event = events[link.event_id] do
      %{
        person_id: link.person_id,
        context: {:event, event.id},
        system: event.external_system,
        scope_id: event.erasure_scope_id
      }
    end
  end

  defp conversation_sightings(_tenant, []), do: []

  defp conversation_sightings(tenant, ids) do
    links =
      ConversationParticipant
      |> Ash.Query.filter(person_id in ^ids)
      |> Ash.Query.select([:person_id, :conversation_id])
      |> Ash.read!(tenant: tenant, authorize?: false)

    conversations = parents(Conversation, Enum.map(links, & &1.conversation_id), tenant)

    for link <- links, conversation = conversations[link.conversation_id] do
      %{
        person_id: link.person_id,
        context: {:conversation, conversation.id},
        system: conversation.external_system,
        scope_id: conversation.erasure_scope_id
      }
    end
  end

  # Structural columns only: titles, subjects and participants are sealed and
  # never read here.
  defp parents(_resource, [], _tenant), do: %{}

  defp parents(resource, ids, tenant) do
    resource
    |> Ash.Query.filter(id in ^Enum.uniq(ids))
    |> Ash.Query.select([:id, :external_system, :erasure_scope_id])
    |> Ash.read!(tenant: tenant, authorize?: false)
    |> Map.new(&{&1.id, &1})
  end

  # Scope → linked account: a connection scope's ref is the account's id.
  defp accounts(sightings) do
    scope_ids = sightings |> Enum.map(& &1.scope_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    case scope_ids do
      [] ->
        %{}

      ids ->
        AshEnterprise.Erasure.Scope
        |> Ash.Query.filter(id in ^ids and kind == :connection)
        |> Ash.Query.select([:id, :ref])
        |> Ash.read!(authorize?: false)
        |> Map.new(&{&1.id, &1.ref})
    end
  end

  defp evidence(sightings) do
    %{
      contexts:
        sightings
        |> Enum.group_by(& &1.person_id, & &1.context)
        |> Map.new(fn {id, contexts} -> {id, MapSet.new(contexts)} end),
      members:
        sightings
        |> Enum.group_by(& &1.context, & &1.person_id)
        |> Map.new(fn {context, ids} -> {context, MapSet.new(ids)} end)
    }
  end
end
