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
  bare `{"id", "status": "cancelled"}` item. A full sync (the first one, and
  every resync after a reset) asks for `showDeleted=true`, so it can also
  return events deleted long ago, sometimes with their full start, end and
  summary. So:

    * the event already has a canonical row → the row is kept, its title and
      times untouched, and its status set to cancelled;
    * it has none, the payload is complete, and `CalendarEvent` can record a
      status → it is created cancelled;
    * it has none, and either the payload is bare or no status can be
      recorded → nothing is created; counted as `:skipped`. Without a status
      attribute, a created row would make a deleted meeting look live to
      every reader of `CalendarEvent`.

  `CalendarEvent` does not have a status attribute yet (that file belongs to
  another change). Until it accepts `:status` on `:upsert_from_source`, the
  status is computed but not written, and a kept row's outcome is
  `:cancelled_unrecorded` so the gap is visible in every sync summary rather
  than silent. `status_supported?/0` reports which world this is.

  ## People are not rewritten across owners

  `Person` is unique on email across the whole tenant. A contact first
  projected from one user's calendar is owned by that user and was written
  under that user's landing scope. When another owner's event names the same
  address, the event links to the existing row and leaves the row alone, so
  no other owner's display name overwrites it. Whether people should be
  scoped per owner or per linked account is an open question for
  `AshEnterprise.Canonical.Person`.

  ## Content and the audit log

  `CalendarEvent` and `Person` are audited (`AshEvents`). The event log stores
  each write's params as `data` and masks only `sensitive?` attributes. Today
  title, location, name and email are not sensitive, so every projection
  would copy them into the central event log in plaintext. That copy sits
  outside the landing scope, so shredding the account would not erase it.
  `audit_exposure/0` lists the exposed attributes. `project/2` and `replay/2`
  refuse to write while that list is non-empty, unless the context sets
  `allow_audited_content?: true`. Only tests over synthetic data set it.

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

  require Ash.Query

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
          optional(:scope) => String.t() | nil,
          optional(:allow_audited_content?) => boolean()
        }

  @type outcome :: :projected | :cancelled | :cancelled_unrecorded | :skipped

  @doc "The `external_system` this projector owns."
  def external_system, do: @external_system

  @doc "The landing stream this projector consumes."
  def stream, do: @stream

  @doc """
  The external id an event lands under: the opaque calendar key
  (`calendar_key/2`) plus Google's event id. Event ids are unique per calendar only,
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
  The opaque, stable key of one provider calendar as one owner sees it:
  `"gcal:"` plus a SHA-256 of the owner id and Google's calendar id. It is the
  first half of every landed event's external id (`external_id/2`).

  It depends only on who owns the linked account and which calendar it is,
  not on the linked account row or its sync cursor. So unlinking and
  relinking the same Google account converges on the same canonical rows
  instead of duplicating them. Two linked accounts of the same person that
  both show one calendar share its rows. A primary calendar's id is an email
  address, which is why the key is a digest and not the id itself.
  """
  @spec calendar_key(Ash.UUID.t(), String.t()) :: String.t()
  def calendar_key(owner_id, calendar_id) when is_binary(owner_id) and is_binary(calendar_id) do
    digest =
      :crypto.hash(:sha256, ["ash_enterprise.calendar_key.v1", 0, owner_id, 0, calendar_id])

    "gcal:" <> Base.encode16(digest, case: :lower)
  end

  # The content attributes a calendar projection writes, per resource.
  @content_attributes [
    {CalendarEvent, [:title, :location]},
    {Person, [:name, :email]}
  ]

  @doc """
  The content attributes a projection would copy into the central audit log
  in plaintext, as `{resource, attribute}` pairs (see "Content and the audit
  log"). Empty once each one is `sensitive?`, the event log is cloaked, or the
  resource is no longer audited.
  """
  @spec audit_exposure() :: [{module(), atom()}]
  def audit_exposure do
    for {resource, names} <- @content_attributes,
        audited_in_plaintext?(resource),
        name <- names,
        attribute = Ash.Resource.Info.attribute(resource, name),
        not is_nil(attribute) and not attribute.sensitive? do
      {resource, name}
    end
  end

  defp audited_in_plaintext?(resource) do
    AshEvents.Events in Spark.extensions(resource) and
      case AshEvents.Events.Info.events_event_log(resource) do
        {:ok, event_log} -> not AshEvents.EventLog.Info.cloaked?(event_log)
        :error -> true
      end
  end

  @doc """
  Whether a projection under `context` may write: nothing would reach the
  audit log in plaintext, or the context explicitly allows it.
  """
  @spec audit_safe?(map()) :: boolean()
  def audit_safe?(context) do
    Map.get(context, :allow_audited_content?, false) == true or audit_exposure() == []
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
  Returns `{:error, :content_would_be_audited}` and writes nothing while
  `audit_safe?/1` is false for `context`.
  """
  @spec project(map(), context()) ::
          {:ok, %{outcome: outcome(), people: [Ash.UUID.t()]}} | {:error, term()}
  def project(%{external_system: system, external_id: external_id, raw_payload: payload}, context)
      when is_binary(external_id) and is_map(payload) do
    if audit_safe?(context),
      do: project_payload(system, external_id, payload, context),
      else: {:error, :content_would_be_audited}
  end

  defp project_payload(system, external_id, payload, context) do
    case event_attributes(payload) do
      # Never create a row for a cancelled event that cannot be marked
      # cancelled (see "Cancellation").
      {:ok, %{status: :cancelled} = attrs} ->
        if status_supported?(),
          do: write_complete(system, external_id, attrs, context),
          else: cancel_existing(system, external_id, context)

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
    if audit_safe?(context),
      do: replay_all(sources, context),
      else: {:error, :content_would_be_audited}
  end

  defp replay_all(sources, context) do
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
  #
  # A person another owner already has is linked, not written (see "People
  # are not rewritten across owners"). The read and the upsert are separate
  # statements, so two owners racing to create the same person both reach the
  # upsert and the later name wins. That is the plain upsert's behaviour, and
  # only on that first insert.
  defp upsert_person(nil, _context), do: {:ok, nil}

  defp upsert_person(%{email: email} = contact, context) do
    case existing_person(email, context) do
      {:ok, %Person{owner_id: owner_id} = person} when owner_id != context.owner_id ->
        {:ok, person}

      {:ok, _own_or_none} ->
        write_person(contact, context)

      {:error, _} = error ->
        error
    end
  end

  defp existing_person(email, context) do
    Person
    |> Ash.Query.filter(email == ^email)
    |> Ash.read_one(tenant: context.tenant_id, authorize?: false)
  end

  defp write_person(%{email: email, name: name}, context) do
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
