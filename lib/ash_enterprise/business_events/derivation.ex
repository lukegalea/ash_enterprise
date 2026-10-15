defmodule AshEnterprise.BusinessEvents.Derivation do
  @moduledoc """
  The mapping from canonical rows to business events (ADR 0051): pure
  functions from a row (and, for a calendar event, the last fact recorded
  about it) to the facts it implies. No reads, no clock, no actor: the same
  inputs always derive the same facts, which is what makes live emission and
  `AshEnterprise.BusinessEvents.backfill/0` converge on one ledger.

  ## The facts

  | Kind | Derived from | `occurred_at` |
  |---|---|---|
  | `calendar_event.scheduled` | first sight of a live event, or a cancelled one reinstated | the row's `updated_at` |
  | `calendar_event.changed` | `starts_at`, `ends_at`, `status` or `organizer_id` differs from the last fact | the row's `updated_at` |
  | `calendar_event.cancelled` | status became `:cancelled` (first sight included) | the row's `updated_at` |
  | `message.received` / `message.sent` | a message, by direction | `sent_at` |
  | `conversation.started` | the first message observed in a conversation | that message's `sent_at` |

  A calendar event's `occurred_at` is the canonical write time, not the
  provider's modification time: the projection does not carry Google's
  `updated` yet, and an honest knowledge-time proxy beats an invented
  truth time. A message's is its `sent_at`, the source's own. A later
  arriving earlier message does not move a conversation's start (that
  correction is BIZEV-9's).

  ## What a fact may carry

  Only what the canonical row holds in the clear: ids, timestamps, statuses,
  directions, the conversation's `kind`, and the row's `erasure_scope_id`.
  Never a sealed field (`title`, `location`, `body`, `subject`,
  `participants`), never a digest of one, never a person's name or address.
  `actor_display` is never set. See the ledger's moduledoc for why that is
  what makes a shred safe here.

  ## Subjects

  A fact's subject is the canonical row's *source identity* — `subject_stream`
  the external system, `subject_external_id` its external id — not the row's
  UUID: deleting the canonical rows and replaying the projection mints new
  UUIDs, and a fact keyed on one would be re-derived as new. The UUID rides
  in `data` for consumers that want to open the row. Rows without a source
  identity (native rows) derive nothing.

  ## Idempotency

  Every fact has a delivery key, so re-deriving it collapses onto the row
  already recorded (`record`'s delivery idempotency). Messages and
  conversations are once-only (`kind` + subject). A calendar event's key is
  its subject plus the id of the last fact about it, so a change derived
  twice from the same predecessor records once, and a change back to an
  earlier state is still a new fact.
  """

  @streams %{
    "calendar" => :calendar,
    "google_calendar" => :google_calendar,
    "gmail" => :gmail,
    "slack" => :slack
  }

  @calendar_state ~w(starts_at ends_at status organizer_id)

  # The mapping as data: what each subject type derives and carries. Its
  # hash is every fact's `provenance.mapping_version_hash`, so a change to
  # what is carried is visible on the rows it produced.
  @declaration [
    calendar_event: [
      kinds: ~w(calendar_event.scheduled calendar_event.changed calendar_event.cancelled),
      carries: ~w(calendar_event_id erasure_scope_id) ++ @calendar_state
    ],
    message: [
      kinds: ~w(message.received message.sent),
      carries: ~w(message_id conversation_id sender_id direction erasure_scope_id)
    ],
    conversation: [
      kinds: ~w(conversation.started),
      carries: ~w(conversation_id first_message_id kind erasure_scope_id)
    ]
  ]

  @version_hash :sha256
                |> :crypto.hash(:erlang.term_to_binary(@declaration))
                |> Base.encode16(case: :lower)

  @type fact :: %{
          event_kind: atom(),
          subject_type: String.t(),
          subject_stream: atom(),
          subject_external_id: String.t(),
          actor_type: String.t() | nil,
          actor_external_id: String.t() | nil,
          occurred_at: DateTime.t(),
          data: map(),
          provenance: map(),
          delivery_key: String.t()
        }

  @doc "The content hash of the mapping declaration."
  @spec version_hash() :: String.t()
  def version_hash, do: @version_hash

  @doc "The external systems facts are derived for, and their stream atoms."
  @spec streams() :: %{String.t() => atom()}
  def streams, do: @streams

  @doc """
  The fact a calendar event's current state implies, given the last fact
  recorded about it (`nil` if none). `[]` when nothing changed.
  """
  @spec calendar_event(map(), map() | nil) :: [fact()]
  def calendar_event(event, last) do
    with {:ok, stream} <- stream(event),
         state = calendar_state(event),
         {kind, changed} <- calendar_kind(last && Map.take(last.data, @calendar_state), state) do
      [
        %{
          event_kind: kind,
          subject_type: "calendar_event",
          subject_stream: stream,
          subject_external_id: event.external_id,
          actor_type: nil,
          actor_external_id: nil,
          occurred_at: event.updated_at,
          data:
            state
            |> Map.merge(%{
              "calendar_event_id" => event.id,
              "erasure_scope_id" => event.erasure_scope_id
            })
            |> put_changed(changed),
          provenance: provenance("calendar_event", event.id),
          delivery_key:
            delivery_key([
              "calendar_event",
              stream,
              event.external_id,
              (last && last.id) || "genesis"
            ])
        }
      ]
    else
      # Not derivable (`:skip`), or nothing changed (`nil`).
      _nothing -> []
    end
  end

  @doc """
  The facts a message implies: received or sent, and — when its
  conversation is given — that conversation's start (which collapses onto
  the first one recorded).
  """
  @spec message(map(), map() | nil) :: [fact()]
  def message(message, conversation) do
    case stream(message) do
      {:ok, stream} ->
        [message_fact(message, stream) | conversation_started(message, conversation)]

      :skip ->
        []
    end
  end

  defp message_fact(message, stream) do
    kind =
      case message.direction do
        :inbound -> :"message.received"
        :outbound -> :"message.sent"
      end

    %{
      event_kind: kind,
      subject_type: "message",
      subject_stream: stream,
      subject_external_id: message.external_id,
      actor_type: message.sender_id && "canonical.person",
      actor_external_id: message.sender_id,
      occurred_at: message.sent_at,
      data: %{
        "message_id" => message.id,
        "conversation_id" => message.conversation_id,
        "sender_id" => message.sender_id,
        "direction" => Atom.to_string(message.direction),
        "erasure_scope_id" => message.erasure_scope_id
      },
      provenance: provenance("message", message.id),
      delivery_key: delivery_key([kind, stream, message.external_id])
    }
  end

  defp conversation_started(_message, nil), do: []

  defp conversation_started(message, conversation) do
    case stream(conversation) do
      {:ok, stream} ->
        [
          %{
            event_kind: :"conversation.started",
            subject_type: "conversation",
            subject_stream: stream,
            subject_external_id: conversation.external_id,
            actor_type: message.sender_id && "canonical.person",
            actor_external_id: message.sender_id,
            occurred_at: message.sent_at,
            data: %{
              "conversation_id" => conversation.id,
              "first_message_id" => message.id,
              "kind" => conversation.kind && Atom.to_string(conversation.kind),
              "erasure_scope_id" => conversation.erasure_scope_id
            },
            provenance: provenance("conversation", conversation.id),
            delivery_key: delivery_key(["conversation.started", stream, conversation.external_id])
          }
        ]

      :skip ->
        []
    end
  end

  # --- calendar ------------------------------------------------------------------

  defp calendar_state(event) do
    %{
      "starts_at" => iso(event.starts_at),
      "ends_at" => iso(event.ends_at),
      "status" => Atom.to_string(event.status),
      "organizer_id" => event.organizer_id
    }
  end

  defp calendar_kind(nil, %{"status" => "cancelled"}), do: {:"calendar_event.cancelled", []}
  defp calendar_kind(nil, _state), do: {:"calendar_event.scheduled", []}

  defp calendar_kind(%{"status" => "cancelled"}, %{"status" => status})
       when status != "cancelled",
       do: {:"calendar_event.scheduled", []}

  defp calendar_kind(%{"status" => previous}, %{"status" => "cancelled"})
       when previous != "cancelled",
       do: {:"calendar_event.cancelled", []}

  defp calendar_kind(previous, state) do
    case Enum.reject(@calendar_state, &(Map.get(previous, &1) == Map.get(state, &1))) do
      [] -> nil
      changed -> {:"calendar_event.changed", changed}
    end
  end

  defp put_changed(data, []), do: data
  defp put_changed(data, changed), do: Map.put(data, "changed", changed)

  # --- shared --------------------------------------------------------------------

  defp stream(%{external_system: system, external_id: id}) when is_binary(id) do
    case Map.fetch(@streams, system) do
      {:ok, stream} -> {:ok, stream}
      :error -> :skip
    end
  end

  defp stream(_row), do: :skip

  defp provenance(subject_type, row_id) do
    %{
      "mapping_name" => "ash_enterprise.canonical." <> subject_type,
      "mapping_version_hash" => @version_hash,
      "source_record_id" => row_id
    }
  end

  # Ids only, hashed so a long external id fits the 512-byte column.
  defp delivery_key(parts) do
    digest =
      :sha256
      |> :crypto.hash(Enum.map_join(parts, <<0>>, &to_string/1))
      |> Base.encode16(case: :lower)

    "derived:" <> digest
  end

  defp iso(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
