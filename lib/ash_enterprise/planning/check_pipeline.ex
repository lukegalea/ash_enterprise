defmodule AshEnterprise.Planning.CheckPipeline do
  @moduledoc """
  Turns a solved run's sealed result into checked `Candidate` rows (ADR 0062).

      CheckPipeline.process(run) :: :ok | {:error, term}

  Called by `RunWorker` after `Run.record_result` with `solve_status` `:optimal` or
  `:feasible`. For every candidate in the decrypted `result_payload`
  (`%{"candidates" => [%{"index", "data", "objective", "checker_output", "checker_ok"}]}`):

    1. **propose** — `Candidate.propose` as the `oban` machinery actor: the assignments lifted
       from the solver's arrays by `Lowering.assignments/2` and sealed, plus the unresolved
       obligations (ids and reason codes: a task left unscheduled, an optional meeting
       declined). Candidates are indexed best-first from 0 (the backend lists oldest first;
       the last incumbent is the best).
    2. **MiniZinc checker** — the verdict the backend recorded while solving
       (`checker_ok`), or, when the backend recorded none, the checker model run against the
       problem data plus the candidate's variables through the same backend: proven
       `:infeasible` is `INCORRECT` (`=====UNSATISFIABLE=====`); an error is
       `:checker_failed`.
    3. **independent Elixir validator** — the module the pinned `ModelVersion` names
       (`validator_module`, loaded from the validator file in `planning_model_dir`, hash
       already verified by `SolverSession.model_paths/1`), called as
       `validate(problem_payload, %{"assignments" => assignments})`. It shares no code with
       the model or the checker.
    4. **record** — a create-only `CheckResult` (statuses and reason codes clear, the checker
       output as a digest, violation details sealed) and `Candidate.record_check` with the
       combined verdict: `:correct` only when both agree it is, `:incorrect` when either says
       so, `:checker_failed` / `:validator_failed` when a verdict could not be produced.

  Idempotent per `(run_id, index)`: a candidate that already exists is not proposed again,
  and one that is already checked is left alone.

  ## Lineage

  One OpenLineage run per solve/check job (`planning` / `solve_check`, run id derived from the
  run id as the correlation), `COMPLETE` or `FAIL`, carrying ONLY the digest facet
  `AshOpenLineage.Event.snapshot_facet/2`: `digest`, `purpose`, `input_count`,
  `definition_kinds`. Never actor, tenant or data; the tenant goes to the store as transport
  metadata, not into the event.
  """

  require Ash.Query
  require Logger

  alias AshEnterprise.Planning
  alias AshPlanning.{Problem, SolveResult}

  alias AshEnterprise.Planning.{
    Candidate,
    Lowering,
    ModelVersion,
    Run,
    SnapshotBuilder,
    SolverSession
  }

  alias AshEnterprise.Platform.SystemActor

  @unsat_marker "=====UNSATISFIABLE====="
  @job_namespace "planning"
  @job_name "solve_check"

  @spec process(struct()) :: :ok | {:error, term()}
  def process(%Run{} = run) do
    tenant = run.organization_id

    with {:ok, result} <- result(run),
         {:ok, payload} <- SnapshotBuilder.problem_payload(run),
         {:ok, snapshot} <- SnapshotBuilder.snapshot_from_payload(payload),
         {:ok, version} <-
           Ash.get(ModelVersion, run.model_version_id, tenant: tenant, authorize?: false),
         {:ok, paths} <- SolverSession.model_paths(version),
         {:ok, validator} <- load_validator(version, paths.validator) do
      ctx = %{run: run, payload: payload, paths: paths, validator: validator, tenant: tenant}

      outcome = check_candidates(ctx, result["candidates"])
      emit(run, snapshot, outcome)
      outcome
    else
      {:error, reason} = error ->
        Logger.warning("planning check pipeline failed for run #{run.id}: #{inspect(reason)}")
        error
    end
  end

  # ── result ─────────────────────────────────────────────────────────────────

  defp result(run) do
    with {:ok, binary} <- SnapshotBuilder.unseal(run, :result_payload, run.organization_id),
         {:ok, %{} = result} <- Jason.decode(binary, floats: :decimals) do
      {:ok, result}
    else
      {:ok, _} -> {:error, :result_unreadable}
      {:error, %Jason.DecodeError{}} -> {:error, :result_unreadable}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── per candidate ──────────────────────────────────────────────────────────

  # Highest index first; the first candidate that fails stops the pass.
  defp check_candidates(ctx, candidates) do
    candidates
    |> List.wrap()
    |> Enum.sort_by(&(&1["index"] || 0), :desc)
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {candidate, position}, :ok ->
      case check_candidate(ctx, candidate, position) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp check_candidate(ctx, candidate, position) do
    with {:ok, assignments} <- Lowering.assignments(ctx.payload, candidate["data"] || %{}),
         {:ok, row} <- propose(ctx, position, assignments) do
      if row.check_status == :unchecked do
        verify(ctx, row, candidate, assignments)
      else
        :ok
      end
    else
      {:error, reason} -> {:error, {:candidate, position, reason}}
    end
  end

  defp propose(ctx, position, assignments) do
    opts = [actor: SystemActor.oban(), tenant: ctx.tenant, authorize?: false]
    run_id = ctx.run.id

    Candidate
    |> Ash.Query.filter(run_id == ^run_id and index == ^position)
    |> Ash.read_one(opts)
    |> case do
      {:ok, nil} ->
        Planning.propose_planning_candidate(
          %{
            run_id: run_id,
            index: position,
            assignments: Jason.encode!(assignments),
            unresolved_obligations: obligations(assignments)
          },
          opts
        )

      other ->
        other
    end
  end

  defp obligations(assignments) do
    Enum.flat_map(assignments, fn
      %{"kind" => "task", "scheduled" => false, "id" => id} ->
        [%{"id" => id, "kind" => "task", "reason" => "unscheduled"}]

      %{"kind" => "meeting", "attended" => false, "id" => id} ->
        [%{"id" => id, "kind" => "meeting", "reason" => "declined"}]

      _ ->
        []
    end)
  end

  defp verify(ctx, row, candidate, assignments) do
    {checker_status, checker_reason, checker_output} = checker(ctx, candidate)
    {validator_status, validator_reason, violations} = validate(ctx, assignments)
    opts = [actor: SystemActor.oban(), tenant: ctx.tenant, authorize?: false]

    with {:ok, _} <-
           Planning.record_planning_check_result(
             %{
               candidate_id: row.id,
               checker_status: checker_status,
               checker_reason: checker_reason,
               validator_status: validator_status,
               validator_reason: validator_reason,
               checker_output_digest: digest(checker_output),
               violation_details: violation_details(violations)
             },
             opts
           ),
         {:ok, _} <-
           Planning.record_planning_check(
             row,
             %{check_status: combine(checker_status, validator_status)},
             opts
           ) do
      :ok
    end
  end

  defp combine(:correct, :correct), do: :correct
  defp combine(:checker_failed, _), do: :checker_failed
  defp combine(_, :validator_failed), do: :validator_failed
  defp combine(:incorrect, _), do: :incorrect
  defp combine(_, :incorrect), do: :incorrect

  # ── MiniZinc checker ───────────────────────────────────────────────────────

  defp checker(_ctx, %{"checker_ok" => ok} = c) when is_boolean(ok),
    do: verdict(ok, c["checker_output"])

  defp checker(_ctx, %{"checker_ok?" => ok} = c) when is_boolean(ok),
    do: verdict(ok, c["checker_output"])

  defp checker(ctx, candidate), do: run_checker(ctx, candidate)

  defp verdict(true, output), do: {:correct, nil, output}
  defp verdict(false, output), do: {:incorrect, "checker_unsatisfiable", output}

  # The backend recorded no verdict: run the checker model over the problem plus the
  # candidate's variables. The checker is satisfiable iff the candidate is correct.
  defp run_checker(ctx, candidate) do
    run = ctx.run

    with {:ok, backend} <- backend(run),
         data = Map.merge(Lowering.solver_data(ctx.payload), candidate["data"] || %{}),
         problem = %Problem{
           model_path: ctx.paths.checker,
           data: data,
           solver: get_in(run.backend, ["solver"]) || "gecode",
           limits: %{time_limit_ms: 30_000}
         },
         {:ok, session} <- backend.start(problem, []),
         {:ok, %SolveResult{} = result} <- backend.await(session, 60_000) do
      case result.status do
        :infeasible -> {:incorrect, "checker_unsatisfiable", @unsat_marker}
        :feasible -> {:correct, nil, nil}
        _ -> {:checker_failed, "checker_no_verdict", nil}
      end
    else
      _ -> {:checker_failed, "checker_error", nil}
    end
  end

  defp backend(run) do
    name = get_in(run.backend || %{}, ["backend"]) || "solverl"

    case Map.fetch(
           SolverSession.config(:backends, %{"solverl" => AshPlanning.Backend.Solverl}),
           name
         ) do
      {:ok, module} -> {:ok, module}
      :error -> :error
    end
  end

  # ── independent validator ──────────────────────────────────────────────────

  defp validate(ctx, assignments) do
    problem = ctx.payload
    candidate = %{"assignments" => assignments}

    case ctx.validator.validate(problem, candidate) do
      :ok ->
        {:correct, nil, []}

      {:error, [_ | _] = violations} ->
        {:incorrect, violations |> hd() |> reason_code(), violations}

      _other ->
        {:validator_failed, "validator_bad_return", []}
    end
  rescue
    _ -> {:validator_failed, "validator_raised", []}
  end

  defp reason_code(%{code: code}) when is_atom(code),
    do: code |> Atom.to_string() |> String.slice(0, 64)

  defp reason_code(%{"code" => code}) when is_binary(code), do: String.slice(code, 0, 64)
  defp reason_code(_), do: "violation"

  # Compiles the pinned validator file when its module is not loaded yet. The file's hash was
  # verified by `SolverSession.model_paths/1`; the module must be the one the version names.
  defp load_validator(%ModelVersion{validator_module: name}, path) do
    module = Module.concat([name])

    cond do
      validator?(module) ->
        {:ok, module}

      File.regular?(path) ->
        modules = path |> Code.compile_file() |> Enum.map(&elem(&1, 0))

        if module in modules and validator?(module),
          do: {:ok, module},
          else: {:error, :validator_missing}

      true ->
        {:error, :validator_missing}
    end
  rescue
    _ -> {:error, :validator_missing}
  end

  defp validator?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :validate, 2)

  # ── sealed details / digests ───────────────────────────────────────────────

  defp violation_details([]), do: nil

  defp violation_details(violations) do
    violations
    |> Enum.map(&jsonable/1)
    |> Jason.encode!()
  end

  defp jsonable(%Decimal{} = d), do: Decimal.to_string(d)
  defp jsonable(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), jsonable(v)} end)
  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)

  defp jsonable(atom) when is_atom(atom) and not is_nil(atom) and not is_boolean(atom),
    do: Atom.to_string(atom)

  defp jsonable(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp jsonable(other), do: inspect(other)

  defp digest(nil), do: nil
  defp digest(output), do: :crypto.hash(:sha256, to_string(output)) |> Base.encode16(case: :lower)

  # ── lineage ────────────────────────────────────────────────────────────────

  # ONE run per solve/check job; the digest facet only. Observational: a transport or facet
  # problem is logged, never allowed to undo checked candidates.
  defp emit(run, snapshot, outcome) do
    type = if outcome == :ok, do: :complete, else: :fail
    run_id = AshOpenLineage.run_id(run.id, @job_namespace, @job_name)

    opts =
      [
        event_type: type,
        job_namespace: @job_namespace,
        job_name: @job_name,
        inputs: [],
        outputs: [],
        producer_name: "#{@job_namespace}.#{@job_name}",
        run_id: run_id,
        correlation_id: run.id
      ] ++ if(type == :fail, do: [error_message: "check_pipeline_failed"], else: [])

    event =
      opts
      |> AshOpenLineage.Event.run_event()
      |> put_in(
        ["run", "facets", AshOpenLineage.Event.snapshot_facet_name()],
        AshOpenLineage.Event.snapshot_facet(snapshot)
      )

    AshOpenLineage.Transport.dispatch(AshOpenLineage.transport(), event, %{
      tenant: run.organization_id
    })
  rescue
    error -> Logger.warning("planning lineage emit failed: #{Exception.message(error)}")
  end
end
