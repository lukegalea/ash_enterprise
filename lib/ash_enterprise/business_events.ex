defmodule AshEnterprise.BusinessEvents do
  @moduledoc """
  The business-event stream (ADR 0051): discrete facts derived from the
  canonical store, recorded in a chained, append-only ledger
  (`AshEnterprise.BusinessEvents.Ledger`, `ash_discrete_business_events`'
  `:ledger` on the platform base).

  The canonical store holds the independent data — what Gmail, Slack and
  Google Calendar say, normalized. This domain derives what *happened* from
  it: a meeting was scheduled, moved or cancelled; a message arrived or went
  out; a conversation started. Each fact is recorded once, as the owner of
  the row it came from, in that row's tenant, and only its owner can read it.

  ## When facts are recorded

  When a projection writes. `CalendarEvent` and `Message`'s
  `upsert_from_source` carry `AshEnterprise.BusinessEvents.Changes.Derive`,
  which records the derived facts in the same transaction as the canonical
  write: a projection either writes the row and its facts, or neither.
  Deriving is idempotent, so a replay, a resync or `backfill/0` records
  nothing it has already recorded.

  A fact is never rewritten. When a message sent before its conversation's
  recorded start is observed later, a new start is recorded that supersedes
  the old one (`supersedes_event_id`, BIZEV-9). When an erasure scope is
  shredded, each owner whose facts point at it gets a
  `:"retention.subject_erased"` tombstone in the same transaction
  (`AshEnterprise.BusinessEvents.Changes.RecordShred`, BIZEV-12's vocabulary).

  ## Not `AshEnterprise.Ledger`

  That namespace is the strangler's change-data ledger over the legacy
  schema (`AshEnterprise.Ledger.UserIngestion`), a different thing: rows
  changed in a database, not facts about a business. The raw layer stays
  `AshEnterprise.Ingestion.SourceObject` and the canonical rows stay
  `AshEnterprise.Canonical`; this domain only adds the facts on top.

  ## Configuration

      config :ash_enterprise, AshEnterprise.BusinessEvents,
        region: :local,          # the ledger region (its chain, lock, feed)
        residency_tag: "local",  # the residency declaration rows carry
        emit?: true              # record facts when projections write

  `config/runtime.exs` sets `region` from `BUSINESS_EVENTS_REGION` and
  `residency_tag` from `CANONICAL_ZONE` (the facts live where the canonical
  store does). Tests default `emit?` to false: the region lock is held until
  a sandboxed test's transaction ends, so concurrent tests would serialize
  on it; the tests that exercise the ledger switch it on.
  """

  use Ash.Domain

  alias AshEnterprise.BusinessEvents.{Ledger, Recorder}
  alias AshEnterprise.Canonical.{CalendarEvent, Message}

  resources do
    resource Ledger
    resource Ledger.SimulationEvent
  end

  @doc "The ledger region facts are recorded in."
  @spec region() :: atom()
  def region, do: config(:region, :local)

  @doc "The residency tag facts carry."
  @spec residency_tag() :: String.t()
  def residency_tag, do: config(:residency_tag, "local")

  @doc "Whether projection writes record facts."
  @spec emit?() :: boolean()
  def emit?, do: config(:emit?, true)

  @doc """
  Derive and record facts for every canonical calendar event and message
  already in the store — the one-time call after this domain is deployed,
  and safe to repeat (it records only what is missing).

  Runs across every tenant, as each row's owner. Calendar events are taken
  in write order and messages in send order, so a conversation's start is
  its earliest message; a start recorded from a later message (live
  emission before corrections existed) is corrected by a superseding fact.
  Returns the rows read and the facts recorded.
  """
  @spec backfill() :: {:ok, map()} | {:error, term()}
  def backfill do
    before = count()

    with {:ok, events} <- each(calendar_events(), &Recorder.calendar_event/1),
         {:ok, messages} <- each(messages(), &Recorder.message/1) do
      {:ok,
       %{
         calendar_events: events,
         messages: messages,
         recorded: count() - before
       }}
    end
  end

  defp each(rows, fun) do
    Enum.reduce_while(rows, {:ok, 0}, fn row, {:ok, seen} ->
      case fun.(row) do
        {:ok, _} -> {:cont, {:ok, seen + 1}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # Only the clear columns the derivation reads: nothing sealed is decrypted
  # to backfill.
  defp calendar_events do
    CalendarEvent
    |> Ash.Query.select([
      :id,
      :external_system,
      :external_id,
      :starts_at,
      :ends_at,
      :status,
      :organizer_id,
      :erasure_scope_id,
      :updated_at,
      :organization_id,
      :owner_id,
      :owning_business_unit_id
    ])
    |> Ash.Query.sort(updated_at: :asc, id: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp messages do
    Message
    |> Ash.Query.select([
      :id,
      :external_system,
      :external_id,
      :sent_at,
      :direction,
      :conversation_id,
      :sender_id,
      :erasure_scope_id,
      :organization_id,
      :owner_id,
      :owning_business_unit_id
    ])
    |> Ash.Query.sort(sent_at: :asc, id: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp count, do: Ash.count!(Ledger, authorize?: false)

  defp config(key, default) do
    :ash_enterprise
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
