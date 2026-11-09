defmodule AshEnterprise.Ledger.UserAnnouncer do
  @moduledoc """
  Tells the rest of the application that a legacy user changed, once the drain has made the
  change durable.

  `Legacy.User` has `ledger?(true)`. Its trigger writes a ledger row and sends only
  `wake:<id>`, and `AshStrangler.Listener` answers a wake by nudging the drain: it re-reads
  nothing and builds no `Ash.Notifier.Notification`. So no notifier on `Legacy.User` ever fires
  for a legacy write on its own, and `/app/legacy-users` (fed by the resource's
  `Ash.Notifier.PubSub`) would go quiet. The drain is the one place that sees every legacy write
  exactly when it has been ingested, so it announces them here, one notification per drained
  event, through `AshStrangler.Listener.notify/2` -- the same function the listener uses for a
  payload-carrying notify, which re-reads the row through Ash and dispatches the notification
  through the resource's notifiers.

  ## After the commit, never inside it

  `AshEnterprise.Ledger.UserDrainWorker` claims, ingests and marks a batch in one transaction,
  and one poison event rolls the whole batch back. A broadcast sent from inside that transaction
  would announce rows whose ingestion was then undone, so the worker calls `announce/1` only
  after `Repo.transaction/1` has returned `{:ok, _}`.

  ## What `notify/2` does with a row that has gone

    * **insert / update:** it re-reads the row by its derived key. If the row has been deleted
      since the event was written (a replayed insert, or a drain that ran late), the read finds
      nothing and `notify/2` returns `:ok` having dispatched nothing. The delete has its own
      ledger event, and that one is announced.
    * **delete:** there is nothing to re-read, so `notify/2` dispatches a destroy notification
      whose record carries only the derived key. Consumers must not expect other fields on it.

  ## At-least-once

  The drain re-runs a batch that rolled back, and an operator can mark an event unprocessed to
  replay it. A replayed event is announced again. That is harmless: the notification says "this
  row changed", every consumer re-reads under its own actor, and the re-read returns the row as
  it is now, whatever the event said.

  ## A failure to announce is logged, never raised

  The batch has already committed. Failing it, or retrying it, because a broadcast raised would
  re-ingest rows that are already ingested and could not un-announce anything, so each event is
  announced under its own `try` and a failure is logged with the ledger event id. The row is
  already in `projected_users`; what a failure costs is one missed live refresh, which the next
  change to that row repairs.
  """

  require Logger

  alias AshEnterprise.Legacy.Estate
  alias AshEnterprise.Legacy.User

  @operations %{"insert" => :insert, "update" => :update, "delete" => :delete}

  @doc """
  Announces every drained event. Always returns `:ok`.

  Call it only after the transaction that ingested `events` has committed.
  """
  @spec announce([map()]) :: :ok
  def announce(events) when is_list(events) do
    Enum.each(events, &announce_one/1)
  end

  defp announce_one(event) do
    case request(event) do
      {:ok, request} -> notify(event, request)
      :skip -> :ok
    end
  end

  defp request(%{operation: operation, primary_key: %{"id" => legacy_id}})
       when is_map_key(@operations, operation) do
    {:ok, %{resource: User, legacy_id: legacy_id, op: Map.fetch!(@operations, operation)}}
  end

  # TRUNCATE, or a key that is not `%{"id" => _}`: nothing this resource can name.
  defp request(_event), do: :skip

  defp notify(event, request) do
    # `authorize?: false` for the same reason the listener's is: the notification is a system
    # event, and every consumer re-reads under its own actor.
    AshStrangler.Listener.notify(request, authorize?: false, tenant: Estate.organization_id())
    :ok
  rescue
    error -> log_failure(event, Exception.format(:error, error, __STACKTRACE__))
  catch
    kind, reason -> log_failure(event, Exception.format(kind, reason, __STACKTRACE__))
  end

  defp log_failure(event, detail) do
    Logger.error(
      "legacy user notification failed for ledger event #{event.id}; " <>
        "the batch is committed and the row is ingested, only the live refresh was missed.\n" <>
        detail
    )

    :ok
  end
end
