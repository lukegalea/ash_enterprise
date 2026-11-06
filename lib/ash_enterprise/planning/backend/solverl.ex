defmodule AshEnterprise.Planning.Backend.Solverl do
  @moduledoc """
  `AshEnterprise.Planning.Backend` on Solverl 1.1.2 / MiniZinc.

  Encodes the Phase 1 spike guardrails (`spike-report.md` §Decision):

    * **Decimals** — numeric values never come from Solverl's decoded solution
      maps (they carry Floats). Raw stdout lines are captured through
      `log_output` and the JSON is re-decoded with `floats: :decimals`.
    * **Checker** — `checker: [path, {:model_text, MinizincData.to_dzn(data)}]`;
      a `=====UNSATISFIABLE=====` checker output is recorded as `checker_ok?: false`.
    * **Infeasible** only on Solverl's proven `:unsatisfiable` summary status.
    * **Governance** — mandatory, no ungoverned mode. The executable is
      `prlimit --as=<bytes> minizinc`; missing `prlimit` refuses with
      `:resource_governor_unavailable` before spawn. Any executable override
      (`:minizinc_executable`/`:executable` in opts or problem) is refused with
      `:invalid_problem`/`:executable_override_not_permitted`.
    * **Cancel** — graceful `stop_solver/1`, 5s grace, then SIGKILL of the recorded
      OS pid plus a recursive descendant sweep (`fzn-gecode` has its own process
      group and traps SIGTERM). Never kills by name; start-time guarded against
      pid reuse; emptiness verified.
    * **Checked solves run sync (upstream Solverl defect)** — async `solve/4` with a
      checker delivers *no* events when the checker fails (verified against MiniZinc
      2.10.1; Solverl was last tested against 2.4.3). `solve_sync/4` works and returns
      `{:error, summary}` carrying the solutions, so a Problem with `checker_path`
      runs `solve_sync` in a linked task. Consequences: checked solves are NOT
      mid-flight cancellable (`cancel/1` returns `{:error, :not_running}`; the
      `time_limit` bounds them), `status/1` is coarse (`stage: :solving`, no
      compile/solve split), and compile errors surface at `await/2`, not `start/2`.
      Unchecked solves stay async and cancellable. A solution-bearing checker failure
      is a `:feasible` result with every candidate `checker_ok?: false`.

  Config (`config :ash_enterprise, #{inspect(__MODULE__)}`): `:minizinc_executable`, `:max_memory_bytes`
  ceiling (default 2_000_000_000), `:max_candidates` retained (default 5),
  `:cancel_grace_ms` (default 5_000).

  Trust boundary: the `:governor_lookup` start option is a TEST-ONLY hook
  (injected lookup for the governance refusal tests). Production callers pass
  no opts beyond `model_path`/`checker_path`/`limits`/`solver` — `RunWorker` and
  `SolverSession` construct the call and never forward external input into it,
  so the hook is reachable only by in-repo code, not by run data. If that
  changes, the hook must become an application-env override with the same
  refusal matrix enforced after lookup.
  """

  @behaviour AshEnterprise.Planning.Backend

  alias AshEnterprise.Planning.Backend
  alias AshEnterprise.Planning.Backend.{Error, Problem, SolveResult}

  require Logger

  @default_memory_ceiling 2_000_000_000
  @default_max_candidates 5
  @default_grace_ms 5_000
  @unsat_marker "=====UNSATISFIABLE====="
  @meta_keys ["_output", "_objective", "_checker", "_time", "_stats"]

  @impl true
  def capabilities do
    Backend.capability_keys()
    |> Map.new(&{&1, false})
    |> Map.merge(%{
      integer_variables: true,
      optional_intervals: true,
      cumulative: true,
      no_overlap: true,
      time_windows: true,
      precedence: true
    })
  end

  @impl true
  def start(problem, opts) do
    with :ok <- reject_override(problem, opts),
         {:ok, %Problem{} = p} <- normalize(problem, opts),
         :ok <- check_files(p),
         {:ok, limits} <- check_limits(p.limits),
         {:ok, executable} <- resolve_executable(p) do
      launch(p, executable, limits)
    end
  end

  @impl true
  def await(%{collector: collector}, timeout) do
    GenServer.call(collector, :await, timeout)
  catch
    :exit, {:timeout, _} ->
      {:error, %Error{kind: :runtime, message: "await_timeout"}}

    :exit, _ ->
      {:error, %Error{kind: :backend_crashed, message: "collector_down"}}
  end

  @impl true
  def status(%{collector: collector}) do
    GenServer.call(collector, :status)
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc "OS pid of the solver process (for callers adding their own belt-and-braces sweep)."
  @spec os_pid(Backend.session_ref()) :: {:ok, pos_integer()} | :error
  def os_pid(%{collector: collector}) do
    case GenServer.call(collector, :info) do
      %{ospid: pid} when is_integer(pid) -> {:ok, pid}
      _ -> :error
    end
  catch
    :exit, _ -> :error
  end

  @impl true
  def cancel(%{collector: collector}) do
    case safe_call(collector, :begin_cancel) do
      %{done?: false, port: port, ospid: ospid} ->
        snapshot = snapshot_tree(ospid)
        stop_graceful(port)

        if wait_tree_gone(snapshot, grace_ms()) do
          :ok
        else
          Logger.warning(
            "planning solver ignored graceful stop; escalating to SIGKILL (ospid #{ospid})"
          )

          hard_kill(ospid, snapshot)
        end

      _ ->
        {:error, :not_running}
    end
  end

  # ── start helpers ──────────────────────────────────────────────────────────

  defp normalize(%Problem{} = p, opts), do: {:ok, merge_opts(p, opts)}

  defp normalize(%{} = map, opts) do
    get = fn key -> Map.get(map, key, Map.get(map, Atom.to_string(key))) end

    case get.(:model_path) || opts[:model_path] do
      nil ->
        {:error, %Error{kind: :invalid_problem, message: "model_path missing"}}

      model_path ->
        {:ok,
         merge_opts(
           %Problem{
             model_path: model_path,
             checker_path: get.(:checker_path),
             data: get.(:data) || %{},
             limits: get.(:limits) || %{}
           },
           opts
         )}
    end
  end

  defp normalize(_other, _opts),
    do: {:error, %Error{kind: :invalid_problem, message: "problem must be a map or Problem"}}

  defp merge_opts(%Problem{} = p, opts) do
    %{
      p
      | model_path: opts[:model_path] || p.model_path,
        checker_path: opts[:checker_path] || p.checker_path,
        limits: Map.merge(p.limits || %{}, Map.new(opts[:limits] || %{})),
        solver: opts[:solver] || p.solver || "gecode",
        opts: Map.new(Keyword.take(opts, [:governor_lookup]))
    }
  end

  defp check_files(%Problem{model_path: model, checker_path: checker}) do
    cond do
      not File.regular?(model) ->
        {:error,
         %Error{kind: :invalid_problem, message: "model file missing", details: %{path: model}}}

      checker && not File.regular?(checker) ->
        {:error,
         %Error{
           kind: :invalid_problem,
           message: "checker file missing",
           details: %{path: checker}
         }}

      true ->
        :ok
    end
  end

  defp check_limits(limits) do
    ceiling = config(:max_memory_bytes, @default_memory_ceiling)
    memory = limit(limits, :memory_bytes) || ceiling

    if memory > ceiling do
      {:error,
       %Error{
         kind: :limit_exceeds_ceiling,
         message: "declared memory limit above ceiling",
         details: %{memory_bytes: memory, ceiling: ceiling}
       }}
    else
      {:ok,
       %{
         memory_bytes: memory,
         time_limit_ms:
           limit(limits, :time_limit_ms) ||
             if(cpu = limit(limits, :cpu_seconds), do: cpu * 1000),
         solution_timeout_ms: limit(limits, :solution_timeout_ms),
         fzn_timeout_ms: limit(limits, :fzn_timeout_ms)
       }}
    end
  end

  defp limit(limits, key), do: Map.get(limits, key, Map.get(limits, Atom.to_string(key)))

  @override_keys [:minizinc_executable, :executable]

  defp reject_override(problem, opts) do
    from_problem =
      case problem do
        %{} = map ->
          Enum.any?(@override_keys, &(Map.has_key?(map, &1) and Map.get(map, &1) != nil))

        _ ->
          false
      end

    from_string =
      case problem do
        %{} = map ->
          Enum.any?(@override_keys, &(Map.get(map, Atom.to_string(&1)) != nil))

        _ ->
          false
      end

    if from_problem or from_string or Enum.any?(@override_keys, &Keyword.has_key?(opts, &1)) do
      {:error,
       %Error{
         kind: :invalid_problem,
         message: "executable override not permitted",
         details: %{reason: :executable_override_not_permitted}
       }}
    else
      :ok
    end
  end

  @doc false
  # Always builds the governed command itself; there is no ungoverned mode and
  # no caller-supplied executable (see `reject_override/2`).
  def resolve_executable(%Problem{opts: opts, limits: limits}) do
    lookup = Map.get(opts, :governor_lookup, fn -> System.find_executable("prlimit") end)

    case lookup.() do
      prlimit when is_binary(prlimit) ->
        build_governed(prlimit, limits)

      _ ->
        {:error,
         %Error{
           kind: :resource_governor_unavailable,
           message: "prlimit not found; refusing ungoverned solve",
           details: %{reason: :governor_missing}
         }}
    end
  end

  defp build_governed(prlimit, limits) do
    case config(:minizinc_executable) || System.find_executable("minizinc") do
      nil ->
        {:error, %Error{kind: :solver_unavailable, message: "minizinc executable not found"}}

      minizinc ->
        memory =
          limit(limits, :memory_bytes) || config(:max_memory_bytes, @default_memory_ceiling)

        exe_ok("#{prlimit} --as=#{memory} #{minizinc}")
    end
  end

  # Solverl splices the executable into a shell command string.
  defp exe_ok(exe) do
    if String.match?(exe, ~r/^[A-Za-z0-9_\/.=\- ]+$/),
      do: {:ok, exe},
      else:
        {:error,
         %Error{kind: :invalid_problem, message: "executable path contains unsafe characters"}}
  end

  defp launch(%Problem{} = p, executable, limits) do
    args = %{problem: p, executable: executable, limits: limits}

    case GenServer.start(__MODULE__.Collector, args) do
      {:ok, collector} ->
        {:ok, %{collector: collector}}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, %Error{kind: :backend_crashed, details: %{reason: inspect(reason)}}}
    end
  end

  @doc false
  def solver_opts(%Problem{} = p, executable, limits, collector) do
    base = [
      solver: p.solver,
      minizinc_executable: executable,
      sync_to: collector,
      log_output: fn line -> send(collector, {:raw_line, line}) end
    ]

    base
    |> put_opt(:time_limit, limits.time_limit_ms)
    |> put_opt(:solution_timeout, limits.solution_timeout_ms)
    |> put_opt(:fzn_timeout, limits.fzn_timeout_ms)
    |> then(fn opts ->
      if p.checker_path do
        Keyword.put(opts, :checker, [p.checker_path, {:model_text, MinizincData.to_dzn(p.data)}])
      else
        opts
      end
    end)
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # ── cancel ladder ──────────────────────────────────────────────────────────

  defp stop_graceful(port) do
    MinizincSolver.stop_solver(port)
  catch
    :exit, _ -> :ok
  end

  defp grace_ms, do: config(:cancel_grace_ms, @default_grace_ms)

  defp wait_tree_gone(snapshot, remaining) when remaining <= 0, do: tree_gone?(snapshot)

  defp wait_tree_gone(snapshot, remaining) do
    if tree_gone?(snapshot) do
      true
    else
      Process.sleep(100)
      wait_tree_gone(snapshot, remaining - 100)
    end
  end

  defp hard_kill(ospid, snapshot) do
    do_hard_kill(ospid, snapshot, 5)
  end

  defp do_hard_kill(_ospid, snapshot, 0) do
    survivors = alive_pids(snapshot)
    Logger.error("planning solver survivors after SIGKILL sweep: #{inspect(survivors)}")
    {:error, {:survivors, survivors}}
  end

  defp do_hard_kill(ospid, snapshot, rounds) do
    # Re-scan each round: children spawned or re-parented since the snapshot.
    targets = Map.merge(snapshot_tree(ospid), snapshot)

    case alive_pids(targets) do
      [] ->
        :ok

      pids ->
        Enum.each(pids, &sigkill/1)
        Process.sleep(100)
        do_hard_kill(ospid, targets, rounds - 1)
    end
  end

  defp sigkill(pid),
    do: System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

  @doc false
  # %{pid => starttime} for `root` and all its descendants (empty if root gone).
  def snapshot_tree(root) when is_integer(root) do
    table = proc_table()

    case Map.fetch(table, root) do
      {:ok, {_state, _ppid, start}} ->
        children = Enum.group_by(table, fn {_pid, {_s, ppid, _t}} -> ppid end, &elem(&1, 0))
        collect(children, table, [root], %{root => start})

      :error ->
        %{}
    end
  end

  defp collect(_children, _table, [], acc), do: acc

  defp collect(children, table, [pid | rest], acc) do
    kids = Map.get(children, pid, [])
    acc = Enum.reduce(kids, acc, fn k, a -> Map.put(a, k, elem(table[k], 2)) end)
    collect(children, table, kids ++ rest, acc)
  end

  defp tree_gone?(snapshot), do: alive_pids(snapshot) == []

  # alive = present, not a zombie, and same start time as when recorded (pid-reuse guard).
  defp alive_pids(snapshot) do
    table = proc_table()

    for {pid, start} <- snapshot,
        match?({state, _, ^start} when state != "Z", Map.get(table, pid)),
        do: pid
  end

  defp proc_table do
    case File.ls("/proc") do
      {:ok, entries} ->
        for entry <- entries,
            String.match?(entry, ~r/^\d+$/),
            {:ok, info} <- [read_stat(entry)],
            into: %{},
            do: {String.to_integer(entry), info}

      _ ->
        %{}
    end
  end

  defp read_stat(pid) do
    with {:ok, content} <- File.read("/proc/#{pid}/stat"),
         [_, rest] <- Regex.run(~r/^\d+ \(.*\) (.*)$/s, content),
         [state, ppid | fields] <- String.split(String.trim(rest), " "),
         start when is_binary(start) <- Enum.at(fields, 17) do
      {:ok, {state, String.to_integer(ppid), start}}
    else
      _ -> :error
    end
  end

  # ── result building (called by the collector) ─────────────────────────────

  @doc false
  def decode_json_object(text) do
    case Jason.decode(text, floats: :decimals) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> :error
    end
  end

  @doc false
  def candidate(index, %{} = decoded) do
    checker = decoded["_checker"]

    %{
      index: index,
      data: decoded |> Map.drop(@meta_keys) |> Map.new(),
      objective: to_decimal(decoded["_objective"]),
      checker_output: checker,
      checker_ok?: if(is_binary(checker), do: not String.contains?(checker, @unsat_marker))
    }
  end

  defp to_decimal(nil), do: nil
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(int) when is_integer(int), do: Decimal.new(int)
  defp to_decimal(_other), do: nil

  @doc false
  # Fallback when only Solverl's decoded solution is available (error path). Floats
  # are converted via their shortest decimal representation, never carried as Float.
  def candidate_from_solution(index, %{} = data), do: candidate(index, deep_decimal(data))

  defp deep_decimal(f) when is_float(f), do: Decimal.new(Float.to_string(f))

  defp deep_decimal(%{} = m) when not is_struct(m),
    do: Map.new(m, fn {k, v} -> {k, deep_decimal(v)} end)

  defp deep_decimal(l) when is_list(l), do: Enum.map(l, &deep_decimal/1)
  defp deep_decimal(other), do: other

  @doc false
  # A checker that rejected (or aborted on) the candidate: recorded, never suppressed.
  def checker_failed(%{} = candidate) do
    output =
      case candidate.checker_output do
        out when is_binary(out) and out != "" -> out
        _ -> @unsat_marker <> "\n"
      end

    %{candidate | checker_ok?: false, checker_output: output}
  end

  @doc false
  def build_result(summary, candidates, total, cancelled?) do
    status = summary[:status]
    reason = reason(summary[:exit_reason], cancelled?)

    {s, complete?, optimality, outcome} =
      cond do
        cancelled? -> incumbent(candidates, :stopped)
        status == :unsatisfiable -> {:infeasible, true, :none, :unsat}
        status == :optimal -> {:feasible, true, :proven, :normal}
        status == :all_solutions -> {:feasible, true, :none, :normal}
        true -> incumbent(candidates, reason)
      end

    %SolveResult{
      status: s,
      complete?: complete?,
      optimality: optimality,
      outcome_reason: outcome,
      payload: %{candidates: candidates},
      stats: %{
        solution_count: total,
        candidates_retained: length(candidates),
        solver: summary[:solver],
        solverl_status: status
      }
    }
  end

  # Timeout/cancel: incumbent => feasible but incomplete; none => unknown (never infeasible).
  defp incumbent([], reason), do: {:unknown, false, :none, reason}
  defp incumbent(_candidates, reason), do: {:feasible, false, :none, reason}

  defp reason(:by_solution_timeout, _), do: :solution_timeout
  defp reason(:by_fzn_timeout, _), do: :fzn_timeout
  defp reason(:by_request, _), do: :stopped
  defp reason(:normal, _), do: :time_limit
  defp reason(_other, _), do: :solver_exit

  @doc false
  def classify_error(text) when is_binary(text) do
    if String.contains?(text, "out of memory"),
      do: %Error{kind: :resource_exhausted, message: String.trim(text)},
      else: %Error{kind: :runtime, message: String.trim(text)}
  end

  def classify_error(other), do: %Error{kind: :runtime, message: inspect(other)}

  @doc false
  def max_candidates, do: config(:max_candidates, @default_max_candidates)

  defp safe_call(pid, msg) do
    GenServer.call(pid, msg)
  catch
    :exit, _ -> nil
  end

  defp config(key, default \\ nil) do
    :ash_enterprise |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end

  defmodule Collector do
    @moduledoc false
    # Owns the Solverl port (links to it), re-decodes raw stdout lines with
    # `floats: :decimals`, and hands the terminal result to awaiters.
    use GenServer

    alias AshEnterprise.Planning.Backend.Error
    alias AshEnterprise.Planning.Backend.Solverl

    @idle_after_done_ms 120_000

    @impl true
    def init(%{problem: p, executable: exe, limits: limits}) do
      Process.flag(:trap_exit, true)
      opts = Solverl.solver_opts(p, exe, limits, self())

      if p.checker_path do
        {:ok, start_sync(p, opts)}
      else
        case start_solver(p, opts) do
          {:ok, port} -> {:ok, new_state(:async, port, ospid(port))}
          {:error, %Error{} = error} -> {:stop, error}
        end
      end
    end

    defp new_state(mode, port, ospid) do
      %{
        mode: mode,
        port: port,
        ospid: ospid,
        started_at: System.monotonic_time(:millisecond),
        buffer: [],
        solverl_solutions: [],
        pending: nil,
        checker_unsat?: false,
        candidates: [],
        total: 0,
        waiters: [],
        result: nil,
        cancelled?: false
      }
    end

    # Upstream Solverl defect: async `solve/4` with a checker delivers no events when
    # the checker fails. `solve_sync/4` works, so checked solves run sync in a linked
    # task and the outcome comes back as `{:sync_done, outcome}`.
    defp start_sync(p, opts) do
      collector = self()

      Task.start_link(fn ->
        outcome =
          try do
            MinizincSolver.solve_sync(p.model_path, p.data, opts)
          rescue
            e -> {:error, %Error{kind: :runtime, message: Exception.message(e)}}
          catch
            :exit, reason -> {:error, %Error{kind: :runtime, message: inspect(reason)}}
          end

        send(collector, {:sync_done, outcome})
      end)

      new_state(:sync, nil, nil)
    end

    defp start_solver(p, opts) do
      case MinizincSolver.solve(p.model_path, p.data, opts) do
        {:ok, port} when is_pid(port) ->
          {:ok, port}

        {:error, text} when is_binary(text) ->
          {:error, %Error{kind: :invalid_model, message: String.trim(text)}}

        {:error, other} ->
          {:error, %Error{kind: :solver_unavailable, message: inspect(other)}}
      end
    rescue
      e -> {:error, %Error{kind: :runtime, message: Exception.message(e)}}
    catch
      :exit, reason -> {:error, %Error{kind: :runtime, message: inspect(reason)}}
    end

    defp ospid(port) do
      MinizincPort.ospid(port)
    catch
      :exit, _ -> nil
    end

    @impl true
    def handle_call(:await, _from, %{result: result} = state) when not is_nil(result),
      do: {:reply, result, state, @idle_after_done_ms}

    def handle_call(:await, from, state),
      do: {:noreply, %{state | waiters: [from | state.waiters]}}

    def handle_call(:status, _from, %{result: result} = state) when not is_nil(result),
      do: {:reply, {:error, :not_running}, state, @idle_after_done_ms}

    # Coarser in sync mode: Solverl's status API needs the port, which solve_sync hides.
    def handle_call(:status, _from, %{mode: :sync} = state) do
      {:reply,
       {:ok,
        %{
          stage: :solving,
          solution_count: state.total,
          running_time_ms: System.monotonic_time(:millisecond) - state.started_at
        }}, state}
    end

    def handle_call(:status, _from, state) do
      reply =
        try do
          case MinizincSolver.solver_status(state.port) do
            {:ok, s} ->
              {:ok,
               %{
                 stage: s.stage,
                 solution_count: s.solution_count,
                 running_time_ms: div(s.running_time, 1000)
               }}

            _ ->
              {:error, :not_running}
          end
        catch
          :exit, _ -> {:error, :not_running}
        end

      {:reply, reply, state}
    end

    def handle_call(:info, _from, state), do: {:reply, %{ospid: state.ospid}, state}

    # Checked (sync-mode) solves are not mid-flight cancellable: report not_running.
    def handle_call(:begin_cancel, _from, %{mode: :sync} = state),
      do: {:reply, %{done?: true, port: nil, ospid: nil}, state}

    def handle_call(:begin_cancel, _from, state) do
      {:reply, %{done?: state.result != nil, port: state.port, ospid: state.ospid},
       %{state | cancelled?: true}}
    end

    @impl true
    def handle_info({:raw_line, line}, state), do: {:noreply, raw_line(line, state)}

    def handle_info(%{solver_results: {:summary, summary}}, state) do
      candidates = Enum.reverse(state.candidates)
      result = {:ok, Solverl.build_result(summary, candidates, state.total, state.cancelled?)}
      {:noreply, finish(state, result)}
    end

    # Solverl's async path streams `:solution` events; with a failing checker MiniZinc
    # exits abnormally, which Solverl reports as `:minizinc_error` (solve_sync folds that
    # into `{:error, summary}`). Solutions found before that are still feasible results
    # whose per-candidate checker verdict is failed — never a whole-solve error.
    def handle_info(%{solver_results: {:solution, solution}}, state) do
      {:noreply, %{state | solverl_solutions: [solution | state.solverl_solutions]}}
    end

    def handle_info(%{solver_results: {:minizinc_error, error}}, state) do
      candidates = Enum.reverse(error_candidates(state))

      result =
        cond do
          state.cancelled? ->
            {:ok, Solverl.build_result(%{}, candidates, state.total, true)}

          candidates != [] ->
            failed = Enum.map(candidates, &Solverl.checker_failed/1)
            {:ok, Solverl.build_result(%{}, failed, length(failed), false)}

          true ->
            {:error, Solverl.classify_error(error[:error] || error)}
        end

      {:noreply, finish(state, result)}
    end

    def handle_info({:sync_done, outcome}, state) do
      {:noreply, finish(state, sync_result(outcome, state))}
    end

    def handle_info({:EXIT, port, reason}, %{port: port, result: nil} = state)
        when reason != :normal or state.cancelled? do
      result =
        if state.cancelled? do
          {:ok, Solverl.build_result(%{}, Enum.reverse(state.candidates), state.total, true)}
        else
          {:error, %Error{kind: :backend_crashed, message: inspect(reason)}}
        end

      {:noreply, finish(state, result)}
    end

    def handle_info(:timeout, %{result: nil} = state), do: {:noreply, state}
    def handle_info(:timeout, state), do: {:stop, :normal, state}
    def handle_info(_other, state), do: {:noreply, state}

    defp finish(state, result) do
      Enum.each(state.waiters, &GenServer.reply(&1, result))
      Process.send_after(self(), :timeout, @idle_after_done_ms)
      %{state | result: result, waiters: []}
    end

    # Maps a `solve_sync` outcome (checked solves). A failing checker makes Solverl return
    # `{:error, summary}` *with* the solutions: those stay feasible candidates, flagged
    # `checker_ok?: false`; only solution-less errors are real solve failures.
    defp sync_result({:ok, %{} = res}, state) do
      candidates = sync_candidates(res[:solutions], state)
      {:ok, Solverl.build_result(res[:summary] || %{}, candidates, length(candidates), false)}
    end

    defp sync_result({:error, %Error{} = error}, _state), do: {:error, error}

    defp sync_result({:error, %{solutions: [_ | _] = solutions}}, state) do
      failed = solutions |> sync_candidates(state) |> Enum.map(&Solverl.checker_failed/1)
      {:ok, Solverl.build_result(%{}, failed, length(failed), false)}
    end

    defp sync_result({:error, %{minizinc_error: error}}, _state),
      do: {:error, Solverl.classify_error(error[:error] || error)}

    defp sync_result({:error, text}, _state) when is_binary(text),
      do: {:error, %Error{kind: :invalid_model, message: String.trim(text)}}

    defp sync_result(other, _state),
      do: {:error, %Error{kind: :runtime, message: inspect(other)}}

    # Prefer decimal-exact raw-line candidates; else Solverl's decoded solutions.
    defp sync_candidates(_solutions, %{candidates: [_ | _] = raw}), do: Enum.reverse(raw)

    defp sync_candidates(solutions, _state) do
      (solutions || [])
      |> Enum.map(&Solverl.candidate_from_solution(&1.index, &1.data))
      |> Enum.take(-Solverl.max_candidates())
    end

    # Prefer decimal-exact raw-line candidates; fall back to Solverl's own solutions.
    defp error_candidates(%{candidates: [_ | _] = candidates}), do: candidates

    defp error_candidates(%{solverl_solutions: solutions}) do
      solutions
      |> Enum.take(Solverl.max_candidates())
      |> Enum.map(fn s -> Solverl.candidate_from_solution(s.index, s.data) end)
    end

    # MiniZinc JSON mode prints one or more `{ ... }` objects (solution, then possibly
    # a checker object) before each "----------". Objects are merged per solution.
    # A bare `=====UNSATISFIABLE=====` line next to a solution is the *checker's*
    # verdict: it marks the candidate `checker_ok?: false` and NEVER drops it. The
    # same line with no solution seen is the solve status (handled by Solverl).
    defp raw_line("----------", state) do
      state |> close_object() |> flush_pending()
    end

    defp raw_line("=====UNSATISFIABLE=====", state) do
      cond do
        state.pending != nil or state.buffer != [] -> %{state | checker_unsat?: true}
        state.total > 0 -> mark_last_checker_failed(state)
        true -> state
      end
    end

    defp raw_line("=" <> _, state), do: state
    defp raw_line("%" <> _, state), do: state
    defp raw_line("", state), do: state

    defp raw_line(line, state) do
      trimmed = String.trim(line)

      cond do
        state.buffer == [] and one_line_object?(trimmed) -> one_line_object(state, trimmed)
        trimmed == "}" -> closing_brace(state, line)
        true -> %{state | buffer: [line | state.buffer]}
      end
    end

    defp one_line_object?(trimmed),
      do: String.starts_with?(trimmed, "{") and String.ends_with?(trimmed, "}")

    defp one_line_object(state, trimmed) do
      case Solverl.decode_json_object(trimmed) do
        {:ok, %{"type" => _}} -> state
        {:ok, decoded} -> merge_pending(state, decoded)
        :error -> state
      end
    end

    defp closing_brace(state, line) do
      buffered = %{state | buffer: [line | state.buffer]}
      text = buffered.buffer |> Enum.reverse() |> Enum.join("\n")

      # nested `}` lines don't yet form valid JSON: keep buffering until they do
      case Solverl.decode_json_object(text) do
        {:ok, decoded} -> merge_pending(%{buffered | buffer: []}, decoded)
        :error -> buffered
      end
    end

    defp close_object(%{buffer: []} = state), do: state

    defp close_object(state) do
      text = state.buffer |> Enum.reverse() |> Enum.join("\n")
      state = %{state | buffer: []}

      case Solverl.decode_json_object(text) do
        {:ok, decoded} -> merge_pending(state, decoded)
        :error -> state
      end
    end

    defp merge_pending(state, decoded),
      do: %{state | pending: Map.merge(state.pending || %{}, decoded)}

    defp flush_pending(%{pending: nil} = state), do: %{state | checker_unsat?: false}

    defp flush_pending(%{pending: decoded, checker_unsat?: unsat?} = state) do
      decoded =
        if unsat? and not is_binary(decoded["_checker"]),
          do: Map.put(decoded, "_checker", "=====UNSATISFIABLE=====\n"),
          else: decoded

      add_candidate(%{state | pending: nil, checker_unsat?: false}, decoded)
    end

    defp mark_last_checker_failed(%{candidates: [last | rest]} = state) do
      last = %{last | checker_output: "=====UNSATISFIABLE=====\n", checker_ok?: false}
      %{state | candidates: [last | rest]}
    end

    defp mark_last_checker_failed(state), do: state

    defp add_candidate(state, decoded) do
      total = state.total + 1

      kept =
        Enum.take(
          [Solverl.candidate(total, decoded) | state.candidates],
          Solverl.max_candidates()
        )

      %{state | candidates: kept, total: total}
    end
  end
end
