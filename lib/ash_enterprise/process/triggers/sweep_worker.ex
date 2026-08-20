defmodule AshEnterprise.Process.Triggers.SweepWorker do
  @moduledoc """
  Walks one tenant's audit chain and starts the processes its triggers ask for.

  **This is the driver.** `AshEnterprise.Process.Triggers.Notifier` only nudges it, and a lost
  nudge costs latency rather than a missed process. The design and the measurements it rests on
  are in `docs/plans/event-triggered-processes.md`.

  ## One cursor, and an arbiter that is not a lock

  The audit table cannot be marked — a Postgres trigger raises on `UPDATE` and `DELETE` — so
  there is no per-row state to reconcile against, and two writers advancing an unmarkable
  stream would be a race with no arbiter.

  **The arbiter is `TriggerDispatch`'s `[:trigger_id, :event_id]` identity, not an advisory
  lock**, and the difference is worth stating because the lock was written first and had to be
  removed. Wrapping a sweep in `pg_advisory_xact_lock` needs one transaction around the batch,
  and one transaction around the batch is exactly what a failing event cannot survive: a
  Postgres error aborts the enclosing transaction, so rescuing the exception leaves every
  subsequent statement in the batch failing too, and a whole sweep disappears on one bad event.
  Found by running it, not by reading it.

  So each event is dispatched in its own transaction and the identity refuses the duplicate.
  Two concurrent sweeps therefore cost duplicated work, not duplicated processes, and Oban's
  `unique` option on the enqueue keeps that rare. A nudge arriving mid-sweep does not block; it
  either finds the cursor advanced or re-dispatches an event whose dispatch row already exists
  and is recorded as `:skipped`.

  Reading `sequence > cursor` is safe because, within a tenant, sequence order is commit order
  — see `AshEnterprise.Audit.EventLog`, which records why and what that depends on.

  ## The cursor advances past failures

  A trigger whose guard raises, whose decision errors, or whose process key has no published
  definition records a `:failed` dispatch **and the cursor still moves**. A broken trigger must
  never wedge the audit stream for a whole tenant. The failure is a queryable row rather than a
  stuck queue, which is the difference between a problem someone finds and a problem someone
  reports.
  """

  use Oban.Worker, queue: :bpmn, max_attempts: 3

  require Ash.Query
  require Logger

  alias AshEnterprise.Platform.{Correlation, SystemActor}
  alias AshEnterprise.Process.{Trigger, TriggerCursor, TriggerDispatch}
  alias AshEnterprise.Process.Triggers.Dispatch

  # Bounded so a tenant with a large backlog is swept in several passes rather than one very
  # long job. The next sweep continues from the cursor.
  @batch 500

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    tenant = args["tenant"]
    cursor = ensure_cursor(tenant)

    case events_after(cursor.last_sequence, tenant) do
      [] ->
        :ok

      events ->
        triggers = published_triggers(tenant)
        Enum.each(events, &dispatch_isolated(&1, triggers, tenant))
        advance(cursor, List.last(events).sequence, tenant)
        :ok
    end
  end

  # Each event is dispatched in **its own transaction**, and what makes two concurrent sweeps
  # safe is the `TriggerDispatch` identity rather than a lock.
  #
  # The obvious design -- one transaction around the batch holding a per-tenant advisory lock
  # -- fails in two ways. A database error anywhere in a Postgres transaction *aborts* it, so
  # one event whose process could not start takes the whole batch with it, other events'
  # instances and the cursor advance included, leaving no record of having tried. And a
  # session-scoped lock needs connection affinity that a pooled repo does not promise.
  #
  # So there is no lock. Three things make that correct:
  #
  #   * Oban's `unique` on `{worker, tenant}` means a second sweep is not usually enqueued.
  #   * If two do run, `TriggerDispatch`'s `[:trigger_id, :event_id]` identity is written **in
  #     the same transaction as the instance start** -- so the loser's insert conflicts and its
  #     instance rolls back with it. The identity is the arbiter, and it is the only one that
  #     works across processes and nodes.
  #   * The cursor makes completeness independent of either: an event missed by a racing sweep
  #     is still behind some cursor and gets picked up.
  #
  # Found by building the alternative: a service task raised and an entire sweep vanished,
  # instance and all.
  defp dispatch_isolated(event, triggers, tenant) do
    AshEnterprise.Repo.transaction(fn -> Dispatch.dispatch_event(event, triggers, tenant) end)
    :ok
  rescue
    e ->
      Logger.error(
        "trigger dispatch for event #{event.id} failed and was rolled back: #{Exception.message(e)}"
      )

      :ok
  end

  @doc """
  Returns this tenant's cursor, creating it at the **current high-water mark** if absent.

  Starting a new cursor at zero would be the obvious thing and is badly wrong: the sweep would
  walk the tenant's entire history and start a process for every historical event that matches.
  On a tenant with a real audit trail that is thousands of processes for things that happened
  months ago, and the first symptom is the queue rather than the mistake.

  A trigger fires on what happens *after* it exists. So a fresh cursor begins at the newest
  event, and this is called when a trigger is published as well as by the sweep — otherwise
  everything between publishing and the first sweep would fall in the gap.
  """
  @spec ensure_cursor(Ash.UUID.t()) :: struct()
  def ensure_cursor(tenant) do
    TriggerCursor
    |> Ash.Query.for_read(:read)
    |> Ash.read_one!(actor: SystemActor.process(), tenant: tenant)
    |> case do
      nil ->
        TriggerCursor.create!(%{last_sequence: current_high_water(tenant)},
          actor: SystemActor.process(),
          tenant: tenant
        )

      cursor ->
        cursor
    end
  end

  defp current_high_water(tenant) do
    AshEnterprise.Audit.EventLog
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(sequence: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
    |> case do
      [%{sequence: sequence}] -> sequence
      [] -> 0
    end
  end

  defp events_after(sequence, tenant) do
    AshEnterprise.Audit.EventLog
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(sequence > ^sequence)
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.Query.limit(@batch)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
  end

  defp published_triggers(tenant) do
    Trigger
    |> Ash.Query.for_read(:published)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
  end

  defp advance(cursor, sequence, tenant) do
    TriggerCursor.advance!(cursor, sequence, actor: SystemActor.process(), tenant: tenant)
  end

  @doc """
  Enqueues a sweep for every tenant that has any published trigger.

  The cron entry. Deliberately per tenant rather than one job walking everything: the ordering
  guarantee the cursor relies on is per tenant, so a global sweep would be a global cursor,
  which the design refuses.
  """
  @spec enqueue_all() :: :ok
  def enqueue_all do
    Trigger
    |> Ash.Query.for_read(:published)
    |> Ash.read!(actor: SystemActor.process(), tenant: nil)
    |> Enum.map(& &1.organization_id)
    |> Enum.uniq()
    |> Enum.each(fn tenant ->
      %{"tenant" => tenant}
      |> new(unique: [period: 5, keys: [:tenant], states: [:available, :scheduled]])
      |> Oban.insert()
    end)

    :ok
  end

  @doc "Correlation helper, so a dispatched process joins the operation that caused it."
  @spec with_event_correlation(map(), (-> any())) :: any()
  def with_event_correlation(event, fun) do
    case get_in(event.metadata, ["correlation_id"]) do
      nil -> fun.()
      id -> Correlation.with_correlation(id, fun)
    end
  end

  @doc false
  def dispatch_resource, do: TriggerDispatch
end
