defmodule AshEnterprise.Process.Triggers.Index do
  @moduledoc """
  An in-memory index of which resources any published trigger cares about.

  ## Why this is not an optimisation

  Without it, the notifier on the audit log would enqueue a sweep job for **every audited write
  in the application** — a cost imposed on the whole system for a feature most tenants will not
  use. With it, the overwhelmingly common case is one ETS lookup that finds nothing and returns.

  ## Deliberately stale, and safe because of what it feeds

  The index is rebuilt on a TTL and on notification, so a newly published trigger can be
  invisible to the *notifier* for up to a minute. That is acceptable only because the notifier
  is a nudge and not the driver: the cron sweep reaches those events regardless, so the cost of
  staleness is latency rather than a missed process.

  This is the same reasoning that lets the notifier be non-transactional
  (`docs/plans/event-triggered-processes.md` §3), and it is the reason both are safe for the
  same underlying reason: the cursor is what makes dispatch complete.
  """

  use GenServer

  require Ash.Query
  require Logger

  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Process.Trigger

  @table :ash_enterprise_trigger_index
  @refresh_ms :timer.seconds(60)

  @doc "Whether any published trigger anywhere matches this resource. One ETS read."
  @spec interested?(String.t()) :: boolean()
  def interested?(resource) when is_binary(resource) do
    case :ets.whereis(@table) do
      :undefined ->
        # Not started -- in a test that does not need it, or during boot. Say no: the cron
        # sweep is the driver, so the only consequence is that the nudge does not fire.
        false

      _ ->
        :ets.member(@table, resource)
    end
  rescue
    ArgumentError -> false
  end

  @doc "Rebuilds now. Called after publishing a trigger, and by the refresh timer."
  @spec refresh() :: :ok
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    load()
    schedule()
    {:noreply, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    load()
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    load()
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :refresh, @refresh_ms)

  # Deliberately cross-tenant: the index answers "does *anyone* care about this resource", and
  # the per-tenant question is answered later by the sweep, inside that tenant's scope. A
  # resource name is not customer data.
  defp load do
    resources =
      Trigger
      |> Ash.Query.for_read(:published)
      |> Ash.read!(actor: SystemActor.process(), tenant: nil)
      |> Enum.map(& &1.match_resource)
      |> Enum.uniq()

    :ets.delete_all_objects(@table)
    :ets.insert(@table, Enum.map(resources, &{&1, true}))
    :ok
  rescue
    e ->
      # A failed rebuild leaves the previous contents rather than emptying the table: stale is
      # better than silent, and the sweep covers both.
      Logger.warning("trigger index refresh failed: #{Exception.message(e)}")
      :ok
  end
end
