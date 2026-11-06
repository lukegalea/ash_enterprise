defmodule AshEnterprise.Planning.SolverSession do
  @moduledoc """
  One solver session per run (ADR 0062), supervised by `AshEnterprise.Planning.SessionSupervisor`
  and registered by run id in `AshEnterprise.Planning.Registry`. The shape is
  `AshEnterprise.Agents.OmpSession`'s: the process exists because a solve is long-lived state,
  never restarts into a second solver for the same run, and ends the run's row itself.

  ## What `start_run/1` refuses, before anything is spawned

  The refusals are returned, not recorded; the caller (`Planning.RunWorker`) turns them into a
  terminal `Run.record_result`.

    * `{:error, :model_missing}`: the pinned `ModelVersion`'s model, checker or validator file
      is absent from `planning_model_dir`, or its sha256 differs from the one the version
      pinned. A published version is immutable; a file that changed under it is not that
      version.
    * `{:error, :resource_governor_unavailable}`: no `prlimit` on `PATH`. A heavy solve never
      runs ungoverned (programme contingency C3).
    * `{:error, :limit_exceeds_ceiling}`: the version's declared `memory_bytes` / `cpu_seconds`
      exceed `planning_memory_bytes` / `planning_cpu_seconds`.
    * `{:error, :unknown_backend}` / `{:error, :problem_unreadable}`: the profile names a
      backend not in the `:backends` allow-list (never `String.to_atom/1` on a profile), or the
      sealed problem cannot be read or decoded (a shredded scope reads as unreadable).
    * `{:error, :heavy_solve_busy}`: every heavy slot is held (`SessionSupervisor`).
    * `{:error, {:already_running, pid}}`: a session for this run is live on this node.

  ## Life of a session

  `init/1` claims a heavy slot. `:launch` then takes the run's lease (`Run.start`, which bumps
  `lease_epoch`), starts the backend, and awaits it in an unlinked task so this process stays
  responsive. A tick every `poll_ms` (a) reads the run row: a recorded cancel request starts the
  cancel ladder, an outcome written by someone else (the lease sweep) stops the solver; and
  (b) renews the lease before it lapses, fenced by the epoch. A renewal that is refused means
  the lease is gone: the solver is killed and the session ends without writing, because the run
  now belongs to whoever replaced it.

  The session writes exactly one outcome, `Run.record_result` fenced by its epoch, and then
  exits `:normal`. A crash or shutdown before that writes nothing: the lease expires and
  `Planning.LeaseSweeper` records `:unknown` / `:lease_lost`.

  ## Cancel ladder (spike guardrail 2)

  1. snapshot the solver's descendants from `/proc/<ospid>/task/*/children`, each pinned to its
     process start time so a recycled pid is never hit;
  2. `backend.cancel/1`: graceful stop, then the backend's own grace and SIGKILL sweep;
  3. SIGKILL every snapshot member still alive (the solver's pid and every descendant:
     `fzn-gecode` has its own process group and traps SIGTERM, so a group signal at the
     minizinc pid is not enough);
  4. verify none survive; only then is the run recorded `:cancelled`.

  Nothing here ever kills by process name.
  """

  use GenServer, restart: :transient, shutdown: 15_000

  require Logger

  alias AshEnterprise.Planning
  alias AshEnterprise.Planning.Backend
  alias AshEnterprise.Planning.Lowering
  alias AshEnterprise.Planning.Registry, as: PlanningRegistry
  alias AshEnterprise.Planning.Run
  alias AshEnterprise.Planning.SessionSupervisor
  alias AshEnterprise.Planning.SolverSession.ProcessTree
  alias AshEnterprise.Platform.SystemActor

  # Sobelow reads `@sobelow_skip` from the source AST; persisting it keeps
  # `--warnings-as-errors` from calling it unused (see Audit.Export).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @default_backends %{"solverl" => AshEnterprise.Planning.Backend.Solverl}
  @key_pattern ~r/\A[a-z][a-z0-9_]{0,63}\z/
  # Slack on top of the declared solve time before this process stops waiting on the backend.
  @deadline_slack_ms 60_000

  # --- configuration ---------------------------------------------------------

  @doc """
  One runtime setting from `config :ash_enterprise, :planning`: `:max_heavy_sessions` (1),
  `:lease_ms` (300_000), `:poll_ms` (2_000), `:backends` (name => module allow-list),
  `:preparer`, `:check_pipeline`, `:prlimit` (binary name), `:sweep_orphans_on_boot?`.
  """
  @spec config(atom(), term()) :: term()
  def config(key, default \\ nil) do
    :ash_enterprise |> Application.get_env(:planning, []) |> Keyword.get(key, default)
  end

  # --- client API ------------------------------------------------------------

  @doc """
  Resolves everything a solve needs and starts the session. See the moduledoc for the refusals.
  """
  @spec start_run(Run.t()) :: {:ok, pid()} | {:error, term()}
  def start_run(%Run{} = run) do
    with {:ok, version} <- load_model_version(run),
         {:ok, backend, identity} <- resolve_backend(version),
         {:ok, limits} <- declared_limits(version),
         :ok <- check_governor(),
         {:ok, paths} <- model_paths(version),
         {:ok, data} <- load_problem(run) do
      problem = %Backend.Problem{
        model_path: paths.model,
        checker_path: paths.checker,
        data: data,
        limits: limits,
        solver: identity["solver"]
      }

      SessionSupervisor.start_session(
        run: run,
        tenant: run.organization_id,
        backend: backend,
        identity: identity,
        problem: problem
      )
    end
  end

  @doc """
  Asks the live session for `run_id` to cancel its solver. The ladder runs in the session, and
  the run ends `:cancelled`. `{:error, :not_running}` when no session is live on this node
  (the run row's `cancellation_reason` is what a session polls, so a request recorded
  through `Run.request_cancel` is honoured even without this call).
  """
  @spec cancel(Ecto.UUID.t()) :: :ok | {:error, :not_running}
  def cancel(run_id) do
    case PlanningRegistry.lookup(run_id) do
      {:ok, pid} -> GenServer.cast(pid, :cancel)
      :error -> {:error, :not_running}
    end
  end

  @doc """
  The pinned artifact files for a model version: `<planning_model_dir>/<key>/<key>.mzn`,
  `<key>.mzc.mzn` and `validator.ex`, each verified against the sha256 the version pinned.

  `{:error, :model_missing}` for an unset directory, a key that is not a plain identifier
  (no path traversal), an absent file, or a hash mismatch.
  """
  @spec model_paths(struct()) ::
          {:ok, %{model: Path.t(), checker: Path.t(), validator: Path.t()}}
          | {:error, :model_missing}
  def model_paths(version) do
    dir = Application.get_env(:ash_enterprise, :planning_model_dir)
    key = version.key

    if is_binary(dir) and is_binary(key) and Regex.match?(@key_pattern, key) do
      base = Path.join(dir, key)

      pinned_paths(%{
        model: {Path.join(base, key <> ".mzn"), version.model_sha256},
        checker: {Path.join(base, key <> ".mzc.mzn"), version.checker_sha256},
        validator: {Path.join(base, "validator.ex"), version.validator_sha256}
      })
    else
      {:error, :model_missing}
    end
  end

  # Every file must be on disk with the content hash the version pinned.
  defp pinned_paths(paths) do
    if Enum.all?(paths, fn {_name, {path, sha}} -> pinned?(path, sha) end) do
      {:ok, Map.new(paths, fn {name, {path, _sha}} -> {name, path} end)}
    else
      {:error, :model_missing}
    end
  end

  # `path` is the configured model directory joined with a key matched against
  # @key_pattern (model_paths/1): never request input.
  @sobelow_skip ["Traversal.FileModule"]
  defp pinned?(path, sha) do
    case File.read(path) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) == sha
      {:error, _} -> false
    end
  end

  # --- resolution ------------------------------------------------------------

  defp load_model_version(run) do
    case Planning.get_model_version(run.model_version_id,
           tenant: run.organization_id,
           authorize?: false
         ) do
      {:ok, version} -> {:ok, version}
      {:error, _} -> {:error, :model_missing}
    end
  end

  defp resolve_backend(version) do
    profile = version.backend_profile || %{}
    name = Map.get(profile, "backend", "solverl")
    backends = config(:backends, @default_backends)

    case Map.fetch(backends, name) do
      {:ok, module} ->
        {:ok, module, %{"backend" => name, "solver" => Map.get(profile, "solver", "gecode")}}

      :error ->
        {:error, :unknown_backend}
    end
  end

  defp declared_limits(version) do
    declared = (version.backend_profile || %{}) |> Map.get("limits", %{})
    memory_ceiling = Application.get_env(:ash_enterprise, :planning_memory_bytes, 2_000_000_000)
    cpu_ceiling = Application.get_env(:ash_enterprise, :planning_cpu_seconds, 900)

    memory = Map.get(declared, "memory_bytes", memory_ceiling)
    cpu = Map.get(declared, "cpu_seconds", cpu_ceiling)
    time_limit = Map.get(declared, "time_limit_ms", cpu * 1000)

    cond do
      not (positive_int?(memory) and positive_int?(cpu) and positive_int?(time_limit)) ->
        {:error, :limit_exceeds_ceiling}

      memory > memory_ceiling or cpu > cpu_ceiling or time_limit > cpu_ceiling * 1000 ->
        {:error, :limit_exceeds_ceiling}

      true ->
        {:ok,
         %{memory_bytes: memory, cpu_seconds: cpu, time_limit_ms: time_limit}
         |> put_optional(:solution_timeout_ms, Map.get(declared, "solution_timeout_ms"))
         |> put_optional(:fzn_timeout_ms, Map.get(declared, "fzn_timeout_ms"))}
    end
  end

  defp positive_int?(value), do: is_integer(value) and value > 0

  defp put_optional(map, key, value) when is_integer(value) and value > 0,
    do: Map.put(map, key, value)

  defp put_optional(map, _key, _value), do: map

  defp check_governor do
    if System.find_executable(config(:prlimit, "prlimit")),
      do: :ok,
      else: {:error, :resource_governor_unavailable}
  end

  defp load_problem(run) do
    with {:ok, loaded} <-
           Ash.load(run, :problem_payload, tenant: run.organization_id, authorize?: false),
         payload when is_binary(payload) <- loaded.problem_payload,
         {:ok, decoded} when is_map(decoded) <- Jason.decode(payload, floats: :decimals) do
      {:ok, Lowering.solver_data(decoded)}
    else
      _ -> {:error, :problem_unreadable}
    end
  end

  # --- GenServer -------------------------------------------------------------

  @doc false
  def start_link(opts) do
    run = Keyword.fetch!(opts, :run)
    GenServer.start_link(__MODULE__, opts, name: PlanningRegistry.via(run.id))
  end

  @impl true
  def init(opts) do
    run = Keyword.fetch!(opts, :run)

    case PlanningRegistry.claim_heavy_slot(run.id, config(:max_heavy_sessions, 1)) do
      {:ok, _slot} ->
        # Trapping exits makes a supervisor shutdown reach terminate/2, where a live
        # solver is killed rather than left to outlive its session.
        Process.flag(:trap_exit, true)

        {:ok,
         %{
           run: run,
           tenant: Keyword.fetch!(opts, :tenant),
           backend: Keyword.fetch!(opts, :backend),
           identity: Keyword.fetch!(opts, :identity),
           problem: Keyword.fetch!(opts, :problem),
           ref: nil,
           os_pid: nil,
           tree: [],
           await: nil,
           cancel_task: nil,
           final: nil,
           lease_ms: config(:lease_ms, 300_000),
           renewed_at: nil,
           done?: false
         }, {:continue, :launch}}

      {:error, :heavy_solve_busy} ->
        {:stop, {:shutdown, :heavy_solve_busy}}
    end
  end

  @impl true
  def handle_continue(:launch, state) do
    params = %{
      backend: state.identity,
      session_pid: "#{node()}:#{inspect(self())}",
      lease_for: state.lease_ms
    }

    case Planning.start_planning_run(state.run, params, machinery(state)) do
      {:ok, started} ->
        launch_backend(%{state | run: started, renewed_at: now_ms()})

      {:error, error} ->
        # Another session, a cancel, or a finished run got there first. Not ours to write.
        Logger.info(
          "planning run #{state.run.id}: not started (#{inspect(Ash.Error.to_error_class(error).__struct__)})"
        )

        stop(%{state | done?: true})
    end
  end

  defp launch_backend(state) do
    limits = state.problem.limits

    opts = [
      model_path: state.problem.model_path,
      checker_path: state.problem.checker_path,
      limits: limits,
      solver: state.problem.solver
    ]

    case state.backend.start(state.problem, opts) do
      {:ok, ref} ->
        backend = state.backend
        timeout = limits.time_limit_ms + @deadline_slack_ms

        task =
          Task.Supervisor.async_nolink(AshEnterprise.TaskSupervisor, fn ->
            backend.await(ref, timeout)
          end)

        Process.send_after(self(), :deadline, timeout)
        Process.send_after(self(), :tick, config(:poll_ms, 2_000))

        os_pid = os_pid(state.backend, ref)

        {:noreply,
         %{state | ref: ref, os_pid: os_pid, tree: ProcessTree.snapshot(os_pid), await: task.ref}}

      {:error, %Backend.Error{} = error} ->
        finish(state, error_args(state, error))
    end
  end

  @impl true
  def handle_cast(:cancel, state) do
    {:noreply, begin_cancel(state, cancelled_args(state))}
  end

  @impl true
  def handle_info(:tick, %{done?: true} = state), do: {:noreply, state}

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, config(:poll_ms, 2_000))
    state = %{state | tree: merge_tree(state.tree, ProcessTree.snapshot(state.os_pid))}

    if state.cancel_task, do: {:noreply, state}, else: poll_run(state)
  end

  def handle_info(:deadline, %{cancel_task: nil, done?: false} = state) do
    # The backend never answered inside the declared time plus slack: the declared limits did
    # not stop it, so stop it here. No incumbent is known to this process: `:unknown`.
    args = %{
      solve_status: :unknown,
      complete?: false,
      optimality: :none,
      outcome_reason: :time_limit,
      stats: %{},
      backend: state.identity
    }

    {:noreply, begin_cancel(state, args)}
  end

  def handle_info(:deadline, state), do: {:noreply, state}

  def handle_info({ref, result}, %{await: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    state = %{state | await: nil}

    if state.cancel_task != nil do
      {:noreply, state}
    else
      finish(state, result_args(state, result))
    end
  end

  def handle_info({ref, _result}, %{cancel_task: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    finish(%{state | cancel_task: nil}, state.final)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{await: ref} = state) do
    state = %{state | await: nil}

    if state.cancel_task != nil do
      {:noreply, state}
    else
      Logger.error("planning run #{state.run.id}: backend await exited (#{inspect(reason)})")
      ProcessTree.kill_all(merge_tree(state.tree, ProcessTree.snapshot(state.os_pid)))
      finish(state, error_args(state, %Backend.Error{kind: :backend_crashed}))
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{cancel_task: ref} = state) do
    finish(%{state | cancel_task: nil}, state.final)
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{done?: false, os_pid: os_pid} = state) when not is_nil(os_pid) do
    # Shutdown or crash with a live solver: no graceful stop, the lease handles the row.
    ProcessTree.kill_all(merge_tree(state.tree, ProcessTree.snapshot(os_pid)))
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- run polling and lease -------------------------------------------------

  defp poll_run(state) do
    case Planning.get_planning_run(state.run.id, tenant: state.tenant, authorize?: false) do
      {:ok, %{solve_status: status}} when not is_nil(status) ->
        # Someone else (the lease sweep) ended the run: the solver has nothing to report to.
        ProcessTree.kill_all(state.tree)
        stop(%{state | done?: true})

      {:ok, %{cancellation_reason: reason}} when not is_nil(reason) ->
        {:noreply, begin_cancel(state, cancelled_args(state))}

      {:ok, row} ->
        # The row's current version: a cancel request written since the last renewal moved it,
        # and the optimistic lock would otherwise refuse our next write.
        renew_lease(%{state | run: row})

      {:error, _} ->
        # A transient read failure is not a reason to lose a solve; the lease deadline is.
        renew_lease(state)
    end
  end

  defp renew_lease(state) do
    if now_ms() - state.renewed_at >= div(state.lease_ms, 3) do
      params = %{epoch: state.run.lease_epoch, lease_for: state.lease_ms}

      case Planning.renew_planning_run_lease(state.run, params, machinery(state)) do
        {:ok, renewed} ->
          {:noreply, %{state | run: renewed, renewed_at: now_ms()}}

        {:error, _error} ->
          Logger.warning("planning run #{state.run.id}: lease lost; killing solver")
          ProcessTree.kill_all(merge_tree(state.tree, ProcessTree.snapshot(state.os_pid)))
          stop(%{state | done?: true})
      end
    else
      {:noreply, state}
    end
  end

  # --- cancel ----------------------------------------------------------------

  defp begin_cancel(%{cancel_task: nil, done?: false, ref: ref} = state, final) when ref != nil do
    tree = merge_tree(state.tree, ProcessTree.snapshot(state.os_pid))
    backend = state.backend

    task =
      Task.Supervisor.async_nolink(AshEnterprise.TaskSupervisor, fn ->
        cancelled = backend.cancel(ref)
        ProcessTree.kill_all(tree)
        cancelled
      end)

    %{state | cancel_task: task.ref, final: final, tree: tree}
  end

  defp begin_cancel(state, _final), do: state

  # --- results ---------------------------------------------------------------

  defp finish(%{done?: true} = state, _args), do: {:stop, :normal, state}

  defp finish(state, args) do
    case record(state, args) do
      :ok ->
        :ok

      {:error, error} ->
        Logger.error(
          "planning run #{state.run.id}: result not recorded (#{inspect(Ash.Error.to_error_class(error).__struct__)})"
        )

        # An outcome the axes refuse (a backend claiming something the contract forbids) is
        # a failed backend, not a result: record that instead, once.
        if args.solve_status != :backend_failed do
          record(state, error_args(state, %Backend.Error{kind: :backend_crashed}))
        end
    end

    stop(%{state | done?: true})
  end

  defp record(state, args) do
    # Re-read for the current `version_number`: someone else may have written the row (a
    # cancel request) since this session last did. The epoch fence, not the version, is what
    # decides whether this session still owns the run.
    run =
      case Planning.get_planning_run(state.run.id, tenant: state.tenant, authorize?: false) do
        {:ok, fresh} -> fresh
        {:error, _} -> state.run
      end

    case Planning.record_planning_result(
           run,
           Map.put(args, :epoch, state.run.lease_epoch),
           machinery(state)
         ) do
      {:ok, _run} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp stop(state), do: {:stop, :normal, state}

  defp result_args(state, {:ok, %Backend.SolveResult{} = result}) do
    {status, optimality} = solve_axes(result)
    complete? = status in [:optimal, :infeasible] or (status == :feasible and result.complete?)

    base = %{
      solve_status: status,
      complete?: complete?,
      optimality: optimality,
      outcome_reason: timeout_reason(result.outcome_reason),
      stats: structural_stats(result.stats),
      backend: state.identity
    }

    if status in [:optimal, :feasible] do
      put_result_payload(base, state, result.payload)
    else
      base
    end
  end

  defp result_args(state, {:error, %Backend.Error{} = error}), do: error_args(state, error)
  defp result_args(state, _other), do: error_args(state, %Backend.Error{kind: :backend_crashed})

  # The backend's status and optimality proof, mapped onto the run's solve axes.
  defp solve_axes(%{status: :feasible, optimality: :proven}), do: {:optimal, :optimal}
  defp solve_axes(%{status: :feasible}), do: {:feasible, :none}
  defp solve_axes(%{status: :infeasible}), do: {:infeasible, :none}
  defp solve_axes(%{status: :unknown}), do: {:unknown, :none}

  defp put_result_payload(base, state, payload) do
    case Jason.encode(payload) do
      {:ok, json} -> Map.put(base, :result_payload, json)
      {:error, _} -> error_args(state, %Backend.Error{kind: :backend_crashed})
    end
  end

  defp timeout_reason(reason) when reason in [:time_limit, :solution_timeout, :fzn_timeout],
    do: reason

  defp timeout_reason(_reason), do: nil

  defp error_args(state, %Backend.Error{kind: kind}) do
    {status, reason} =
      case kind do
        :invalid_model ->
          {:invalid_model, nil}

        :resource_governor_unavailable ->
          {:backend_failed, :resource_governor_unavailable}

        kind when kind in [:limit_exceeds_ceiling, :resource_exhausted] ->
          {:backend_failed, :memory_limit}

        _ ->
          {:backend_failed, :backend_error}
      end

    %{
      solve_status: status,
      complete?: false,
      optimality: :none,
      outcome_reason: reason,
      stats: %{},
      backend: state.identity
    }
  end

  defp cancelled_args(state) do
    %{
      solve_status: :cancelled,
      complete?: false,
      optimality: :none,
      outcome_reason: nil,
      stats: %{},
      backend: state.identity
    }
  end

  # Structural counts and timings only: scalars under string keys. Anything numeric-valued
  # and non-integer (a decimal objective) stays out of the clear column.
  defp structural_stats(stats) when is_map(stats) do
    for {key, value} <- stats,
        is_integer(value) or is_boolean(value) or is_atom(value),
        into: %{} do
      {to_string(key), value}
    end
  end

  defp structural_stats(_), do: %{}

  # --- helpers ---------------------------------------------------------------

  defp machinery(state), do: [actor: SystemActor.oban(), tenant: state.tenant]

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp os_pid(backend, ref) do
    with true <- Code.ensure_loaded?(backend),
         true <- function_exported?(backend, :os_pid, 1),
         {:ok, pid} when is_integer(pid) and pid > 1 <- backend.os_pid(ref) do
      pid
    else
      _ -> nil
    end
  end

  defp merge_tree(left, right), do: Enum.uniq(left ++ right)

  defmodule ProcessTree do
    @moduledoc false
    # The solver's process tree, read from /proc. Entries are `{pid, start_time}`: the start
    # time (clock ticks since boot) pins an entry to one process, so a pid the kernel recycled
    # after the solver exited is never signalled.

    # Sobelow reads `@sobelow_skip` from the source AST; persisting it keeps
    # `--warnings-as-errors` from calling it unused (see Audit.Export).
    Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

    @type entry :: {pos_integer(), String.t()}

    @spec snapshot(pos_integer() | nil) :: [entry()]
    def snapshot(nil), do: []

    def snapshot(pid) when is_integer(pid) and pid > 1 do
      case start_time(pid) do
        nil -> []
        start -> [{pid, start} | descendants(pid)]
      end
    end

    defp descendants(pid) do
      for child <- children(pid),
          start = start_time(child),
          start != nil,
          entry <- [{child, start} | descendants(child)] do
        entry
      end
    end

    # Reads only /proc/<integer pid>/task/*/children: never request input.
    @sobelow_skip ["Traversal.FileModule"]
    defp children(pid) do
      "/proc/#{pid}/task/*/children"
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        case File.read(path) do
          {:ok, text} -> text |> String.split() |> Enum.flat_map(&parse_pid/1)
          {:error, _} -> []
        end
      end)
      |> Enum.uniq()
    end

    defp parse_pid(text) do
      case Integer.parse(text) do
        {pid, ""} when pid > 1 -> [pid]
        _ -> []
      end
    end

    # Field 22 of /proc/<pid>/stat. The command name (field 2) may contain spaces and
    # parentheses, so count fields after the *last* closing paren (field 3 is index 0).
    # `pid` is an integer from /proc: never request input.
    @sobelow_skip ["Traversal.FileModule"]
    defp start_time(pid) do
      with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
           fields = stat |> String.split(")") |> List.last() |> String.split(),
           start when is_binary(start) <- Enum.at(fields, 19) do
        start
      else
        _ -> nil
      end
    end

    @doc "SIGKILL every entry still alive; true when none survive after a short settle."
    @spec kill_all([entry()]) :: boolean()
    def kill_all(entries) do
      kill_alive(entries)
      settle(entries, 20)
    end

    defp kill_alive(entries) do
      for {pid, _start} = entry <- entries, alive?(entry) do
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
      end

      :ok
    end

    defp settle(entries, attempts) do
      cond do
        not Enum.any?(entries, &alive?/1) ->
          true

        attempts == 0 ->
          false

        true ->
          Process.sleep(50)
          kill_alive(entries)
          settle(entries, attempts - 1)
      end
    end

    defp alive?({pid, start}), do: start_time(pid) == start
  end
end
