defmodule AshEnterprise.Process.Triggers.SweepWorker do
  @moduledoc """
  Walks one tenant's audit chain and starts the processes its triggers ask for.

  **This is the driver.** `AshEnterprise.Process.Triggers.Notifier` only nudges it, and a lost
  nudge costs latency rather than a missed process. The design and the measurements it rests on
  are in `docs/plans/event-triggered-processes.md`.

  ## One writer, holding a lock, walking a cursor

  The audit table cannot be marked — a Postgres trigger raises on `UPDATE` and `DELETE` — so
  there is no per-row state to reconcile against, and two writers advancing an unmarkable
  stream is a race with no arbiter. So a sweep takes a per-tenant advisory lock: a nudge
  arriving mid-sweep blocks and then finds the cursor already advanced.

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

  # Bounded so one sweep cannot hold the lock indefinitely on a tenant with a large backlog.
  # The next sweep continues from the cursor.
  @batch 500

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    tenant = args["tenant"]

    AshEnterprise.Repo.transaction(fn ->
      lock(tenant)

      cursor = cursor_for(tenant)
      events = events_after(cursor.last_sequence, tenant)

      case events do
        [] ->
          :ok

        events ->
          triggers = published_triggers(tenant)
          Enum.each(events, &Dispatch.dispatch_event(&1, triggers, tenant))
          advance(cursor, List.last(events).sequence, tenant)
      end
    end)

    :ok
  end

  # Serializes sweeps for one tenant. Transaction-scoped, so it is released at COMMIT and a
  # crashed sweep does not leave the tenant permanently locked.
  #
  # A two-argument key in the same shape AshEvents uses, but with a distinct first element:
  # this must not contend with the append lock, or a sweep would block every audited write for
  # the tenant it is sweeping.
  defp lock(tenant) do
    Ecto.Adapters.SQL.query!(
      AshEnterprise.Repo,
      "SELECT pg_advisory_xact_lock($1, $2)",
      [:erlang.phash2(__MODULE__), :erlang.phash2(tenant)]
    )
  end

  defp cursor_for(tenant) do
    TriggerCursor
    |> Ash.Query.for_read(:read)
    |> Ash.read_one!(actor: SystemActor.process(), tenant: tenant)
    |> case do
      nil ->
        TriggerCursor.create!(%{last_sequence: 0}, actor: SystemActor.process(), tenant: tenant)

      cursor ->
        cursor
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
