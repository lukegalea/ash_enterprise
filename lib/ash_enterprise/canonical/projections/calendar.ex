defmodule AshEnterprise.Canonical.Projections.Calendar do
  @moduledoc """
  Google Calendar event → `AshEnterprise.Canonical.CalendarEvent` (+ `Person`
  for the organizer and attendees), the real-calendar projector of epic E4
  (ADR 0037's host-declared pattern, dogfood §11).

  Input is anything carrying `external_system`, `external_id` and
  `raw_payload` — an `AshEnterprise.Integration.SourceRecord` the sync step has
  just landed, or a (decrypted) `AshEnterprise.Ingestion.SourceObject` read
  back for replay. The payload is one item of Google's `events.list` response,
  verbatim. Everything written is a function of that payload plus the replay
  context (whose rows these are); no clock, no actor state, so replaying the
  same sources converges on the same rows.

  ## Mapping (v1, deliberately crude)

  | Canonical | Google event |
  |---|---|
  | `title` | `summary`; `"(no title)"` when absent (busy-only and untitled events) |
  | `starts_at` / `ends_at` | `start`/`end` `.dateTime` (offset → UTC), or all-day `.date` at 00:00 UTC |
  | `location` | `location` |
  | `organizer` | `Person` upserted on `organizer.email` |
  | status | `status`: confirmed / tentative / cancelled — see "Cancellation" |

  Attendees become `Person` rows on their email, the v1 linkage key; room and
  equipment attendees (`resource: true`) are not people and are skipped. There
  is no attendee join on `CalendarEvent` yet, so attendance itself is not
  projected. A recurring event is projected as its master (first occurrence's
  times); modified or cancelled instances are their own rows.

  ## Cancellation

  A cancelled event must not vanish. Incremental syncs report a deletion as a
  bare `{"id", "status": "cancelled"}` item, so:

    * the event already has a canonical row → the row is kept, its title and
      times untouched, and its status set to cancelled;
    * it has none, but the payload is complete → it is created cancelled;
    * it has none and the payload is bare → nothing to keep; counted as
      `:skipped`.

  `CalendarEvent` does not have a status attribute yet (that file belongs to
  another change). Until it accepts `:status` on `:upsert_from_source`, the
  status is computed but not written, and the outcome is
  `:cancelled_unrecorded` so the gap is visible in every sync summary rather
  than silent. `status_supported?/0` reports which world this is.

  ## The iCalUID is not written (yet)

  `CalendarEvent.unique_provider_uid` is `[external_system, external_uid]`
  across the whole tenant, but real calendars repeat an iCalUID across every
  calendar that shows the meeting, across every attendee's copy, and across a
  recurring event's modified instances. Writing it would make the second copy
  of any shared meeting fail its upsert. Until that identity is scoped, the
  iCalUID stays in the raw payload only.

  ## Zones and scope (ADR 0042, ADR 0024)

  These are real people's events. The sync step projects only records that
  `AshEnterprise.Integration.Landing.land/2` accepted, which by default is
  none: the default lander refuses until scoped (crypto-shredded) landing is
  wired. The landing scope travels into every canonical write as changeset
  context (`:landing_scope`) for the scoped-encryption work to pick up.
  """

  alias AshEnterprise.Canonical.{CalendarEvent, Person}

  @external_system "google_calendar"
  @stream "calendar.events"

  @title_max 1024
  @location_max 512
  @external_id_max 512
  @untitled "(no title)"

  @statuses %{"confirmed" => :confirmed, "tentative" => :tentative, "cancelled" => :cancelled}

  @type context :: %{
          required(:owner_id) => Ash.UUID.t(),
          required(:tenant_id) => Ash.UUID.t(),
          optional(:business_unit_id) => Ash.UUID.t() | nil,
          optional(:actor) => term(),
          optional(:scope) => String.t() | nil
        }

  @type outcome :: :projected | :cancelled | :cancelled_unrecorded | :skipped

  @doc "The `external_system` this projector owns."
  def external_system, do: @external_system

  @doc "The landing stream this projector consumes."
  def stream, do: @stream

  @doc """
  The external id an event lands under: the opaque calendar key (the sync
  cursor's id) plus Google's event id. Event ids are unique per calendar only,
  and the same meeting carries the same id on every attendee's calendar, so the
  bare event id would collide across calendars and accounts.

  An over-long id is replaced by a digest so one odd event cannot wedge a sync.
  """
  @spec external_id(String.t(), String.t()) :: String.t()
  def external_id(calendar_key, event_id) when is_binary(calendar_key) and is_binary(event_id) do
    id = calendar_key <> "/" <> event_id

    if byte_size(id) <= @external_id_max do
      id
    else
      calendar_key <> "/sha256:" <> Base.encode16(:crypto.hash(:sha256, event_id), case: :lower)
    end
  end

  @doc """
  Whether `CalendarEvent` can record a status yet (see "Cancellation").
  """
  @spec status_supported?() :: boolean()
  def status_supported? do
    :status in Ash.Resource.Info.action(CalendarEvent, :upsert_from_source).accept
  end

  @doc """
  The pure part: a Google event payload to the attributes it projects to.

  Returns `{:ok, attrs}` for a payload with a usable start and end, or
  `{:bare, status}` for one without (a deleted event as incremental sync
  reports it, or a malformed one).
  """
  @spec event_attributes(map()) :: {:ok, map()} | {:bare, atom()}
  def event_attributes(payload) when is_map(payload) do
    status = status(payload)

    with {:ok, starts_at} <- event_time(payload["start"]),
         {:ok, ends_at} <- event_time(payload["end"]) do
      {:ok,
       %{
         status: status,
         title: payload |> Map.get("summary") |> title(),
         starts_at: starts_at,
         ends_at: ends_at,
         location: payload |> Map.get("location") |> clip(@location_max),
         organizer: contact(payload["organizer"]),
         attendees:
           payload
           |> Map.get("attendees", [])
           |> List.wrap()
           |> Enum.reject(&(is_map(&1) and &1["resource"] == true))
           |> Enum.map(&contact/1)
           |> Enum.reject(&is_nil/1)
       }}
    else
      :error -> {:bare, status}
    end
  end

  @doc """
  Project one landed source into canonical rows.

  Returns `{:ok, %{outcome: outcome, people: [person_id]}}`, or
  `{:error, error}` when a canonical write fails (the error is an Ash error;
  callers must not log or persist it verbatim — it can carry the payload).
  """
  @spec project(map(), context()) ::
          {:ok, %{outcome: outcome(), people: [Ash.UUID.t()]}} | {:error, term()}
  def project(%{external_system: system, external_id: external_id, raw_payload: payload}, context)
      when is_binary(external_id) and is_map(payload) do
    case event_attributes(payload) do
      {:ok, attrs} ->
        write_complete(system, external_id, attrs, context)

      {:bare, :cancelled} ->
        cancel_existing(system, external_id, context)

      {:bare, _status} ->
        {:ok, %{outcome: :skipped, people: []}}
    end
  end

  @doc """
  Project many sources; returns the outcome counts and the distinct people
  touched. Stops at the first failed write.
  """
  @spec replay([map()], context()) :: {:ok, map()} | {:error, term()}
  def replay(sources, context) do
    initial = %{
      projected: 0,
      cancelled: 0,
      cancelled_unrecorded: 0,
      skipped: 0,
      people: MapSet.new()
    }

    sources
    |> Enum.reduce_while({:ok, initial}, fn source, {:ok, acc} ->
      case project(source, context) do
        {:ok, %{outcome: outcome, people: people}} ->
          {:cont,
           {:ok,
            acc
            |> Map.update!(outcome, &(&1 + 1))
            |> Map.update!(:people, &Enum.into(people, &1))}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, %{acc | people: MapSet.size(acc.people)}}
      error -> error
    end
  end

  # --- writes ------------------------------------------------------------------

  defp write_complete(system, external_id, attrs, context) do
    with {:ok, organizer} <- upsert_person(attrs.organizer, context),
         {:ok, attendees} <- upsert_people(attrs.attendees, context),
         {:ok, _event} <-
           upsert_event(
             %{
               external_system: system,
               external_id: external_id,
               title: attrs.title,
               starts_at: attrs.starts_at,
               ends_at: attrs.ends_at,
               location: attrs.location,
               organizer_id: organizer && organizer.id
             },
             attrs.status,
             context
           ) do
      people =
        [organizer | attendees]
        |> Enum.reject(&is_nil/1)
        |> Enum.map(& &1.id)
        |> Enum.uniq()

      {:ok, %{outcome: outcome_for(attrs.status), people: people}}
    end
  end

  # A bare cancellation: keep the row we have, flip its status, touch nothing
  # else. The required title/times are re-supplied from the row itself because
  # the upsert is a create and validates them.
  defp cancel_existing(system, external_id, context) do
    case CalendarEvent.by_external(system, external_id,
           tenant: context.tenant_id,
           authorize?: false
         ) do
      {:ok, nil} ->
        {:ok, %{outcome: :skipped, people: []}}

      {:ok, event} ->
        with {:ok, _event} <-
               upsert_event(
                 %{
                   external_system: system,
                   external_id: external_id,
                   title: event.title,
                   starts_at: event.starts_at,
                   ends_at: event.ends_at,
                   location: event.location,
                   organizer_id: event.organizer_id
                 },
                 :cancelled,
                 context
               ) do
          {:ok, %{outcome: outcome_for(:cancelled), people: []}}
        end

      {:error, _} = error ->
        error
    end
  end

  defp upsert_event(attrs, status, context) do
    attrs =
      attrs
      |> Map.merge(owner_attrs(context))
      |> maybe_put_status(status)

    CalendarEvent
    |> Ash.Changeset.for_create(:upsert_from_source, attrs,
      tenant: context.tenant_id,
      actor: Map.get(context, :actor),
      authorize?: false,
      context: write_context(context)
    )
    |> Ash.create()
  end

  defp maybe_put_status(attrs, status) do
    if status_supported?(), do: Map.put(attrs, :status, status), else: attrs
  end

  defp outcome_for(:cancelled) do
    if status_supported?(), do: :cancelled, else: :cancelled_unrecorded
  end

  defp outcome_for(_status), do: :projected

  defp upsert_people(contacts, context) do
    contacts
    |> Enum.reduce_while({:ok, []}, fn contact, {:ok, acc} ->
      case upsert_person(contact, context) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, person} -> {:cont, {:ok, [person | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, people} -> {:ok, Enum.reverse(people)}
      error -> error
    end
  end

  # Same upsert contract as `AshEnterprise.Canonical.Projection`'s: the email
  # identity, and a name-less contact never blanks an existing name. The full
  # upsert option set is repeated at call time on purpose (see the comment in
  # Projection.upsert_person/2).
  defp upsert_person(nil, _context), do: {:ok, nil}

  defp upsert_person(%{email: email, name: name}, context) do
    Person
    |> Ash.Changeset.for_create(
      :upsert_from_source,
      Map.merge(%{email: email, name: name}, owner_attrs(context)),
      tenant: context.tenant_id,
      actor: Map.get(context, :actor),
      authorize?: false,
      context: write_context(context)
    )
    |> Ash.create(
      upsert?: true,
      upsert_identity: :unique_email,
      upsert_fields: if(is_nil(name), do: [], else: [:name])
    )
  end

  defp owner_attrs(context) do
    %{
      owner_id: context.owner_id,
      owner_type: :user,
      owning_user_id: context.owner_id,
      owning_business_unit_id: Map.get(context, :business_unit_id)
    }
  end

  defp write_context(context) do
    case Map.get(context, :scope) do
      nil -> %{}
      scope -> %{landing_scope: scope}
    end
  end

  # --- payload readers -----------------------------------------------------------

  defp status(%{"status" => status}) when is_binary(status),
    do: Map.get(@statuses, status, :confirmed)

  defp status(_payload), do: :confirmed

  defp title(summary) when is_binary(summary) do
    case String.trim(summary) do
      "" -> @untitled
      trimmed -> clip(trimmed, @title_max)
    end
  end

  defp title(_summary), do: @untitled

  defp clip(value, max) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, max)
    end
  end

  defp clip(_value, _max), do: nil

  # Timed events carry `dateTime` (RFC 3339 with an offset); all-day events
  # carry `date`, projected at 00:00 UTC — the event's own time zone is not
  # applied in v1.
  defp event_time(%{"dateTime" => iso}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp event_time(%{"date" => iso}) when is_binary(iso) do
    with {:ok, date} <- Date.from_iso8601(iso),
         {:ok, datetime} <- DateTime.new(date, ~T[00:00:00], "Etc/UTC") do
      {:ok, datetime}
    else
      _ -> :error
    end
  end

  defp event_time(_), do: :error

  # v1 has no fuzzy resolution: a contact without an email is not linked.
  defp contact(%{"email" => email} = contact) when is_binary(email) do
    case String.trim(email) do
      "" ->
        nil

      # Longer than any deliverable address (RFC 5321) and than Person.email
      # accepts: not a contact worth linking.
      trimmed when byte_size(trimmed) > 320 ->
        nil

      trimmed ->
        name =
          case contact["displayName"] do
            name when is_binary(name) -> clip(name, 256)
            _ -> nil
          end

        %{email: trimmed, name: name}
    end
  end

  defp contact(_), do: nil
end
