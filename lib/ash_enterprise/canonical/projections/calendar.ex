defmodule AshEnterprise.Canonical.Projections.Calendar do
  @moduledoc """
  Google Calendar event → `AshEnterprise.Canonical.CalendarEvent` (+ `Person`
  for the organizer and attendees), the real-calendar projector of epic E4
  (ADR 0037's host-declared pattern, dogfood §11).

  Input is anything carrying `external_system`, `external_id` and
  `raw_payload` — an `AshEnterprise.Integration.SourceRecord` the sync step has
  just landed, or an `AshEnterprise.Ingestion.SourceObject` read back for
  replay (`replay_landed/2`, which reads through the decrypting path). The
  payload is one item of Google's `events.list` response, verbatim. Everything
  written is a function of that payload plus the replay context (whose rows
  these are, and which erasure scope seals them); no clock, no actor state, so
  replaying the same sources converges on the same rows.

  ## Mapping (v1, deliberately crude)

  | Canonical | Google event |
  |---|---|
  | `title` | `summary`; `"(no title)"` when absent (busy-only and untitled events) |
  | `starts_at` / `ends_at` | `start`/`end` `.dateTime` (offset → UTC), or all-day `.date` at 00:00 UTC |
  | `location` | `location` |
  | `organizer` | `Person` upserted on `organizer.email` |
  | `status` | `status`: confirmed / tentative / cancelled — see "Cancellation" |

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

    * the payload is complete → the row is written (or created) with
      `status: :cancelled`;
    * the payload is bare and the event already has a canonical row → the row
      is kept, its title and times untouched, and its status set to
      cancelled;
    * the payload is bare and there is no row → nothing is created; counted
      as `:skipped`. There is nothing to show for a meeting never seen.

  ## People are not rewritten across owners

  `Person` is unique on email across the whole tenant. A contact first
  projected from one user's calendar is owned by that user and was written
  under that user's landing scope. When another owner's event names the same
  address, the event links to the existing row and leaves the row alone, so
  no other owner's display name overwrites it. Whether people should be
  scoped per owner or per linked account is an open question for
  `AshEnterprise.Canonical.Person`.

  ## Erasure (ADR 0024)

  Every `CalendarEvent` is written with the `erasure_scope_id` of the source it
  was projected from — the source's own (a landed `SourceObject`), or the
  context's (`:erasure_scope_id`, the scope the sync step just landed the
  record under). Its `title` and `location` are sealed under that scope's key,
  so shredding the linked account's scope reaches the raw landing, the
  canonical row and the ciphertext their audit events carry, in one key
  destroy. A projection without a scope is refused (`:erasure_scope_required`).
  A source whose scope is already shredded has nothing left to project and is
  counted as `:shredded`.

  `Person` rows are not sealed (`AshEnterprise.Canonical.Person`, "Erasure"):
  their name and email are `sensitive?`, so the audit log records them as
  `nil`; the rows themselves outlive a shred. The end-to-end erasure test
  (`test/ash_enterprise/integration/erasure_e2e_test.exs`) sweeps the whole
  audit log for every synthetic content string after a shred.

  ## The iCalUID is not written (yet)

  `CalendarEvent.unique_provider_uid` is `[external_system, external_uid]`
  across the whole tenant, but real calendars repeat an iCalUID across every
  calendar that shows the meeting, across every attendee's copy, and across a
  recurring event's modified instances. Writing it would make the second copy
  of any shared meeting fail its upsert. Until that identity is scoped, the
  iCalUID stays in the raw payload only.

  ## Zones (ADR 0042)

  These are real people's events. The sync step projects only records that
  `AshEnterprise.Integration.Landing.land/2` accepted under the linked
  account's scope. Calendar is the one vertical projected without a zone gate:
  the dogfood decision is that the operator's own calendar is admitted.
  """

  alias AshEnterprise.Canonical.{CalendarEvent, Person}
  alias AshEnterprise.Erasure.Shredded
  alias AshEnterprise.Ingestion.SourceObject

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
          optional(:erasure_scope_id) => Ash.UUID.t() | nil
        }

  @type outcome :: :projected | :cancelled | :skipped | :shredded

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
  The opaque, stable key of one provider calendar as one linked account sees
  it: `"gcal:"` plus a SHA-256 of the linked account id and Google's calendar
  id. It is the first half of every landed event's external id
  (`external_id/2`).

  Keyed by the **linked account**, not its owner, because every landed row
  lives under exactly one erasure scope, one per linked account (ADR 0024), and
  a landing never moves a row to another scope. Two linked accounts that both
  show one calendar therefore land (and project) two copies, each erased with
  its own account. Relinking an account is a new linked account and a new
  scope: its events land afresh, and the old account's rows stay under the old
  scope until that is shredded. A primary calendar's id is an email address,
  which is why the key is a digest and not the id itself.
  """
  @spec calendar_key(Ash.UUID.t(), String.t()) :: String.t()
  def calendar_key(linked_account_id, calendar_id)
      when is_binary(linked_account_id) and is_binary(calendar_id) do
    digest =
      :crypto.hash(:sha256, [
        "ash_enterprise.calendar_key.v2",
        0,
        linked_account_id,
        0,
        calendar_id
      ])

    "gcal:" <> Base.encode16(digest, case: :lower)
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
  Returns `{:error, :erasure_scope_required}` and writes nothing when neither
  the source nor the context names an erasure scope.
  """
  @spec project(map(), context()) ::
          {:ok, %{outcome: outcome(), people: [Ash.UUID.t()]}} | {:error, term()}
  def project(
        %{external_system: system, external_id: external_id, raw_payload: payload} = source,
        context
      )
      when is_binary(external_id) do
    cond do
      Shredded.shredded?(payload) ->
        {:ok, %{outcome: :shredded, people: []}}

      not is_map(payload) ->
        {:ok, %{outcome: :skipped, people: []}}

      true ->
        case Map.get(source, :erasure_scope_id) || Map.get(context, :erasure_scope_id) do
          nil ->
            {:error, :erasure_scope_required}

          scope_id ->
            project_payload(
              system,
              external_id,
              payload,
              Map.put(context, :erasure_scope_id, scope_id)
            )
        end
    end
  end

  defp project_payload(system, external_id, payload, context) do
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
      skipped: 0,
      shredded: 0,
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

  @doc """
  Replay everything landed through one linked account: its `SourceObject` rows
  on this projector's stream, read back through the decrypting path (each row
  carries its own `erasure_scope_id`, which the canonical rows inherit). Rows
  whose scope has been shredded are counted as `:shredded`, never projected.
  """
  @spec replay_landed(Ash.UUID.t(), context()) :: {:ok, map()} | {:error, term()}
  def replay_landed(linked_account_id, context) when is_binary(linked_account_id) do
    SourceObject
    |> Ash.Query.filter(external_system == ^@external_system)
    |> Ash.Query.filter(source_metadata["stream"] == ^@stream)
    |> Ash.Query.filter(source_metadata["linked_account_id"] == ^linked_account_id)
    |> Ash.Query.sort(:external_id)
    |> Ash.read!(authorize?: false)
    |> replay(Map.delete(context, :erasure_scope_id))
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

      # Its scope is gone; there is no title left to keep.
      {:ok, %CalendarEvent{title: %Shredded{}}} ->
        {:ok, %{outcome: :shredded, people: []}}

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
      |> Map.merge(%{status: status, erasure_scope_id: context.erasure_scope_id})

    CalendarEvent
    |> Ash.Changeset.for_create(:upsert_from_source, attrs,
      tenant: context.tenant_id,
      actor: Map.get(context, :actor),
      authorize?: false
    )
    |> Ash.create()
  end

  defp outcome_for(:cancelled), do: :cancelled
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
      authorize?: false
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
