defmodule AshEnterprise.Planning.RunWorker do
  @moduledoc """
  Drives one planning run from request to recorded outcome (ADR 0062), as the machinery:

      %{"run_id" => uuid}

  Enqueue with `enqueue/1` (after `Run.request`). Args are the run id and nothing else: what to
  solve is the run row's, never the job's.

  ## The steps, each re-entered safely

  Every `perform/1` reads the run and does the next step its row calls for, so a retry, a
  duplicate delivery or a Lifeline rescue lands on the right step and repeats nothing:

  | Row | Step |
  |---|---|
  | `solve_status` set | already ended: run the check pipeline (idempotent) and finish |
  | preparation `:needs_input` / `:preparation_failed` | nothing to solve; finish |
  | started (`lease_epoch > 0`), no outcome | a live local session: wait for it. None, lease lapsed: end the run (`LeaseSweeper.expire/1`). None, lease live: snooze past the lease |
  | cancel on record, never started | record `:cancelled` |
  | preparation `:pending` | `SnapshotBuilder.prepare/1`, then continue |
  | `:prepared`, never started | `SolverSession.start_run/1` and wait for the session to end |

  The worker never records a solver outcome itself: the session does, fenced by the lease
  epoch. What the worker records are the *refusals* `SolverSession.start_run/1` returns before a
  solver exists (missing model file, no `prlimit`, limits over the ceiling, ...), each as a
  terminal `:backend_failed` with its reason code, and a cancel that beat the start.

  ## Idempotency (Iron Law #07)

  Unique per `run_id` in **every** job state, forever: one job per run however many times it is
  enqueued. Terminal writes are `Run.record_result`, fenced by `lease_epoch` and a still-empty
  `solve_status`, so a second writer's attempt is refused rather than overwriting; a refused
  terminal write is re-read and treated as success when the run has an outcome. The check
  pipeline is idempotent per `(run, candidate index)` by its contract.

  Jobs are bounded to three attempts. `heavy_solve_busy` snoozes (it is back-pressure, not a
  failure). Errors Oban persists are structural strings: an Ash error can quote what it was
  writing.

  ## Collaborators, by runtime lookup

  The snapshot builder and the check pipeline are looked up in `config :ash_enterprise,
  :planning` (`:preparer`, `:check_pipeline`; defaults `SnapshotBuilder` and `CheckPipeline`),
  so a test can substitute them without this module knowing.
  """

  use Oban.Worker,
    queue: :planning,
    max_attempts: 3,
    unique: [period: :infinity, keys: [:run_id], states: :all]

  alias AshEnterprise.Planning
  alias AshEnterprise.Planning.LeaseSweeper
  alias AshEnterprise.Planning.Registry, as: PlanningRegistry
  alias AshEnterprise.Planning.Run
  alias AshEnterprise.Planning.SolverSession
  alias AshEnterprise.Platform.SystemActor

  # `start_run/1` refusals => the terminal outcome they record.
  @refusals %{
    model_missing: {:backend_failed, :model_missing},
    resource_governor_unavailable: {:backend_failed, :resource_governor_unavailable},
    limit_exceeds_ceiling: {:backend_failed, :memory_limit},
    unknown_backend: {:backend_failed, :backend_error},
    problem_unreadable: {:backend_failed, :backend_error}
  }

  @busy_snooze_seconds 15

  @doc "Enqueues the job for `run_id`. A second enqueue for the same run is a no-op (unique)."
  @spec enqueue(Ecto.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(run_id) when is_binary(run_id) do
    %{"run_id" => run_id} |> new() |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id}}) when is_binary(run_id) do
    case fetch(run_id) do
      {:ok, run} -> advance(run)
      {:error, :not_found} -> {:cancel, "planning run not found"}
      {:error, :read_failed} -> {:error, "planning: run could not be read"}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, "planning run job requires a run_id"}

  # --- state machine ---------------------------------------------------------

  defp advance(%Run{solve_status: status} = run) when not is_nil(status), do: post_process(run)

  defp advance(%Run{preparation_status: status})
       when status in [:needs_input, :preparation_failed],
       do: :ok

  defp advance(%Run{lease_epoch: epoch} = run) when epoch > 0, do: resume(run)

  defp advance(%Run{cancellation_reason: reason} = run) when not is_nil(reason),
    do: refuse(run, {:cancelled, nil})

  defp advance(%Run{preparation_status: :pending} = run), do: prepare(run)
  defp advance(%Run{preparation_status: :prepared} = run), do: launch(run)

  defp prepare(run) do
    case preparer().prepare(run) do
      {:ok, %Run{preparation_status: :prepared} = prepared} -> advance(prepared)
      {:ok, %Run{}} -> :ok
      {:error, error} -> {:error, "planning: preparation failed (#{describe(error)})"}
    end
  end

  defp launch(run) do
    case SolverSession.start_run(run) do
      {:ok, pid} -> await_session(run, pid)
      {:error, {:already_running, pid}} -> await_session(run, pid)
      {:error, :heavy_solve_busy} -> {:snooze, @busy_snooze_seconds}
      {:error, reason} when is_map_key(@refusals, reason) -> refuse(run, @refusals[reason])
      {:error, error} -> {:error, "planning: session did not start (#{describe(error)})"}
    end
  end

  # The session ends the run itself; this process only waits for it, so that the job's state
  # is the solve's state and the queue's concurrency bounds heavy work.
  defp await_session(run, pid) do
    monitor = Process.monitor(pid)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    end

    case fetch(run.id) do
      {:ok, %Run{solve_status: status} = ended} when not is_nil(status) -> post_process(ended)
      {:ok, _no_outcome} -> {:error, "planning: session ended without recording an outcome"}
      {:error, _} -> {:error, "planning: run could not be read"}
    end
  end

  defp resume(run) do
    case PlanningRegistry.lookup(run.id) do
      {:ok, pid} ->
        await_session(run, pid)

      :error ->
        if lease_lapsed?(run) do
          case LeaseSweeper.expire(run) do
            :ok -> :ok
            {:error, _} -> settled_or_error(run)
          end
        else
          {:snooze, seconds_until_lapse(run) + 1}
        end
    end
  end

  defp post_process(%Run{solve_status: status} = run) when status in [:optimal, :feasible] do
    case check_pipeline().process(run) do
      :ok -> :ok
      {:error, error} -> {:error, "planning: check pipeline failed (#{describe(error)})"}
    end
  end

  defp post_process(_run), do: :ok

  # --- terminal writes -------------------------------------------------------

  defp refuse(run, {status, reason}) do
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
      {:ok, _ended} -> :ok
      {:error, _error} -> settled_or_error(run)
    end
  end

  # A refused fenced write is fine when the run has an outcome by now (someone else ended it).
  defp settled_or_error(run) do
    case fetch(run.id) do
      {:ok, %Run{solve_status: status}} when not is_nil(status) -> :ok
      _ -> {:error, "planning: outcome could not be recorded"}
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp fetch(run_id) do
    case Planning.get_planning_run(run_id, authorize?: false) do
      {:ok, run} ->
        {:ok, run}

      {:error, error} ->
        case Ash.Error.to_error_class(error) do
          %Ash.Error.Invalid{errors: errors} ->
            if Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)),
              do: {:error, :not_found},
              else: {:error, :read_failed}

          _ ->
            {:error, :read_failed}
        end
    end
  end

  defp lease_lapsed?(%Run{lease_expires_at: nil}), do: true

  defp lease_lapsed?(%Run{lease_expires_at: at}),
    do: DateTime.compare(at, DateTime.utc_now()) != :gt

  defp seconds_until_lapse(%Run{lease_expires_at: at}),
    do: max(DateTime.diff(at, DateTime.utc_now(), :second), 1)

  defp preparer, do: SolverSession.config(:preparer, AshEnterprise.Planning.SnapshotBuilder)

  defp check_pipeline,
    do: SolverSession.config(:check_pipeline, AshEnterprise.Planning.CheckPipeline)

  # Structural description only: the error's class or the atom, never its message.
  defp describe(%{__exception__: true} = error),
    do: inspect(Ash.Error.to_error_class(error).__struct__)

  defp describe(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp describe(%{__struct__: struct}), do: inspect(struct)
  defp describe(_other), do: "unrecognised"
end
