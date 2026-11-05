defmodule AshEnterprise.Planning.LeaseSweeper do
  @moduledoc """
  The recovery net for planning runs whose solver session is gone (ADR 0062).

  A running solve holds a lease on its run row (`lease_epoch` + `lease_expires_at`) and renews
  it while the session lives. A session that died, a node that went away, a solver that wedged
  past its deadline: none of them write an outcome, so the lease simply lapses. This worker,
  on the Oban cron (`config/config.exs`, every minute), finds runs with **no outcome and an
  expired lease** and ends them:

    * with a cancel on record: `:cancelled`;
    * otherwise: `:unknown` with outcome reason `:lease_lost`. Never `:infeasible`, never a
      guess: nobody knows what the solver found.

  The write is `Run.record_result` fenced by the run's current `lease_epoch`, so a session that
  is in fact alive and renews between the read and the write wins, and a second sweeper tick (or
  a second node's) over the same run is a refused no-op. A run with a live session on *this*
  node is skipped: the session renews, or ends the run itself.

  `sweep_orphans/0` is the boot-time backstop (`AshEnterprise.Application`, mirroring
  `OmpSession.fail_orphaned_runs/0`): every started, outcome-less run with no session in this
  node's registry is ended the same way, without waiting for the lease. The registry it checks
  is LOCAL; with several BEAMs sharing one database leave
  `config :ash_enterprise, :planning, sweep_orphans_on_boot?` on only for the node that owns
  the solver.

  Idempotent by construction: a run with an outcome is not selected.
  """

  use Oban.Worker,
    queue: :planning,
    max_attempts: 1,
    unique: [period: 50, states: [:available, :scheduled, :executing, :retryable]]

  require Ash.Query
  require Logger

  alias AshEnterprise.Planning
  alias AshEnterprise.Planning.Registry, as: PlanningRegistry
  alias AshEnterprise.Planning.Run
  alias AshEnterprise.Platform.SystemActor

  @batch 200

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    Run
    |> Ash.Query.filter(
      is_nil(solve_status) and not is_nil(lease_expires_at) and lease_expires_at < ^now
    )
    |> Ash.Query.limit(@batch)
    |> Ash.read!(authorize?: false)
    |> Enum.each(&expire_unowned/1)

    :ok
  end

  @doc """
  Boot backstop: ends every started run without an outcome that has no live session on this
  node. Returns `:ok` even when a row cannot be ended (logged); a boot task must not crash.
  """
  @spec sweep_orphans() :: :ok
  def sweep_orphans do
    Run
    |> Ash.Query.filter(is_nil(solve_status) and lease_epoch > 0)
    |> Ash.read!(authorize?: false)
    |> Enum.each(&expire_unowned/1)
  rescue
    exception ->
      Logger.error("planning orphan sweep failed (#{inspect(exception.__struct__)})")
      :ok
  end

  defp expire_unowned(run) do
    case PlanningRegistry.lookup(run.id) do
      {:ok, _pid} -> :ok
      :error -> expire(run)
    end
  end

  @doc """
  Ends `run` as the sweep would: `:cancelled` if a cancel is on record, else `:unknown` /
  `:lease_lost`. `:ok` when written; `{:error, error}` when the fenced write is refused (the run
  moved on: for a caller that only wants the run ended, the refusal is the idempotent answer).
  """
  @spec expire(Run.t()) :: :ok | {:error, term()}
  def expire(%Run{} = run) do
    {status, reason} =
      if run.cancellation_reason,
        do: {:cancelled, nil},
        else: {:unknown, :lease_lost}

    params = %{
      solve_status: status,
      complete?: false,
      optimality: :none,
      outcome_reason: reason,
      epoch: run.lease_epoch
    }

    case Planning.record_planning_result(run, params,
           actor: SystemActor.oban(),
           tenant: run.organization_id
         ) do
      {:ok, _ended} ->
        :ok

      {:error, error} ->
        Logger.info(
          "planning run #{run.id}: lease expiry not recorded (#{inspect(Ash.Error.to_error_class(error).__struct__)})"
        )

        {:error, error}
    end
  end
end
