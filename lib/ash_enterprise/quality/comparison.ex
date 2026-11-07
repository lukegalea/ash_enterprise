defmodule AshEnterprise.Quality.Comparison do
  @moduledoc """
  Candidates compared on the same cases (ADR 0058, R2 AI-03, AI-17, AI-18): the suite runs
  of one suite side by side, a candidate per column and a case per row, with safety in a
  lane of its own that is never averaged into, or traded against, the quality aggregate.

  `read/3` reads the suite, its most recent suite runs, their case results and the agent
  versions they pinned, as the caller, and `build/4` lays them out. Nothing is written.

  ## The candidates

  One per suite run of the suite, oldest first, the eight most recent at most. The **baseline** is the
  suite run named by `:baseline`, else the oldest finished one that was not imported; the
  others are compared with it case by case.

  ## The quality lane

  One row per ordinary case (every case not tagged `injection`). A cell is the case's
  result in that run, compared with the baseline's:

    * `:improved`: it passed where the baseline failed or errored;
    * `:degraded`: it failed or errored where the baseline passed;
    * `:passed`, `:failed`, `:errored`: as recorded, when the comparison changes nothing
      (or for the baseline itself, or when the baseline has no decided result);
    * `:skipped`: the run chose not to run it;
    * `:unmeasured`: it ran, and no assertion could be measured;
    * `:missing`: the run has no result for the case at all.

  Any other status is passed through as it is, and counts as neither measured nor passed.

  `:unmeasured` and `:missing` are never a pass, a fail or a zero. The aggregate counts
  them, and a candidate's `rate` (passed over every ordinary case of the suite, so a
  missing case counts against it) is `nil`, not measured, when it has no ordinary result.

  ## The safety lane

  Apart from quality: the hard assertions that failed and the prohibited effects asked for,
  over every case, and each injection case as its own row (`:held` when it passed,
  `:attacked` when an attack assertion failed, else its status). A candidate's `safety` is

    * `:failed` when a hard assertion failed, a prohibited effect was asked for, or an
      injection case failed;
    * else `:not_measured` when its run has not finished, a case has no result, an
      injection case did not pass, or a case with a hard assertion neither passed nor
      failed (errored, skipped, unmeasured or anything else): missing evidence is never
      read as safety;
    * else `:clear`.

  ## Recommended

  Among the candidates that finished, were run here (not `imported`), have every case
  measured and whose safety is `:clear`, the one with the highest quality `rate`. No
  candidate is recommended when fewer than two are compared, when none qualifies, or when
  the best rate is shared. A candidate's `blocked` says why it does not qualify. The
  recommendation is a count over the suite's cases, not a significance test.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Execution
  alias AshEnterprise.Quality
  alias AshEnterprise.Quality.{Assertions, Injection}

  @columns 8
  @attack ["prohibited_effect", "tool_not_called"]

  @type outcome ::
          :improved
          | :degraded
          | :passed
          | :failed
          | :errored
          | :skipped
          | :unmeasured
          | :missing
          | :held
          | :attacked

  @doc "How many suite runs a comparison shows at most."
  @spec columns() :: pos_integer()
  def columns, do: @columns

  @impl true
  def run(input, _opts, context) do
    read(input.arguments.suite_id, input.arguments[:baseline_id], Ash.Context.to_opts(context))
  end

  @doc """
  The comparison of the suite `suite_id`'s most recent suite runs, read as the caller
  (`opts`: `actor:`, `tenant:`, `authorize?:`). `:baseline` names the suite run to compare
  with. `{:error, error}` when the suite is not one the caller may read.
  """
  @spec read(Ash.UUID.t(), Ash.UUID.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def read(suite_id, baseline_id, opts) do
    with {:ok, suite} <- Quality.get_suite(suite_id, opts) do
      runs =
        opts
        |> Keyword.put(:query,
          filter: [suite_id: suite.id],
          sort: [created_on: :desc],
          limit: @columns
        )
        |> Quality.list_suite_runs!()
        |> Enum.reverse()

      ids = Enum.map(runs, & &1.id)

      results =
        Quality.list_case_results!(Keyword.put(opts, :query, filter: [suite_run_id: [in: ids]]))

      versions =
        case Enum.reject(Enum.map(runs, & &1.agent_version_id), &is_nil/1) do
          [] ->
            %{}

          version_ids ->
            opts
            |> Keyword.put(:query, filter: [id: [in: Enum.uniq(version_ids)]])
            |> Execution.list_agent_versions!()
            |> Map.new(&{&1.id, &1})
        end

      {:ok, build(suite, runs, results, baseline: baseline_id, versions: versions)}
    end
  end

  @doc """
  Lays `runs` of `suite` out with their case `results`. `:versions` maps an agent version
  id to the version the caller could read; `:baseline` names the suite run to compare
  with.
  """
  @spec build(map(), [map()], [map()], keyword()) :: map()
  def build(suite, runs, results, opts \\ []) do
    cases = suite.cases || []
    {injection, ordinary} = Enum.split_with(cases, &Injection.injection?/1)
    by_run = index(results)
    baseline = baseline(runs, opts[:baseline])

    candidates =
      Enum.map(runs, fn run ->
        candidate(run, Map.get(by_run, run.id, %{}), cases, ordinary, injection, opts)
      end)

    quality = Enum.map(ordinary, &quality_row(&1, runs, by_run, baseline))

    candidates =
      Enum.map(candidates, fn candidate ->
        block(%{candidate | quality: tally(candidate.quality, quality, candidate.id)})
      end)

    {recommended, reason} = recommend(candidates)

    %{
      suite: %{
        id: suite.id,
        key: suite.key,
        version: suite.version,
        content_hash: suite.content_hash,
        cases: length(cases),
        ordinary: length(ordinary),
        injection: length(injection)
      },
      baseline_id: baseline && baseline.id,
      candidates: candidates,
      quality: quality,
      safety: safety_rows(injection, runs, by_run, candidates),
      missing: Enum.sum(Enum.map(candidates, & &1.missing)),
      recommended: recommended,
      reason: reason
    }
  end

  # The first epoch of each case of each run.
  defp index(results) do
    results
    |> Enum.group_by(& &1.suite_run_id)
    |> Map.new(fn {run_id, rows} ->
      {run_id,
       rows
       |> Enum.sort_by(& &1.epoch)
       |> Enum.reduce(%{}, fn row, acc -> Map.put_new(acc, row.case_id, row) end)}
    end)
  end

  defp baseline(runs, id) do
    Enum.find(runs, &(id != nil and &1.id == id)) ||
      Enum.find(runs, &(&1.status == :finished and not &1.imported))
  end

  defp candidate(run, results, cases, ordinary, injection, opts) do
    version = Map.get(opts[:versions] || %{}, run.agent_version_id)
    missing = Enum.count(cases, &(not Map.has_key?(results, &1[:id])))
    {safety, safety_reasons} = safety(run, results, cases, injection, missing)

    %{
      id: run.id,
      mode: run.mode,
      status: run.status,
      imported: run.imported,
      agent_key: run.agent_key,
      agent_version_id: run.agent_version_id,
      version: version && version.version,
      digest: run.candidate_digest,
      started_at: run.created_on,
      finished_at: run.finished_at,
      missing: missing,
      safety: safety,
      safety_reasons: safety_reasons,
      quality: %{cases: length(ordinary)},
      blocked: []
    }
  end

  ## Quality

  defp quality_row(c, runs, by_run, baseline) do
    base = baseline && result_status(by_run, baseline.id, c[:id])

    cells =
      Map.new(runs, fn run ->
        result = get_in(by_run, [run.id, c[:id]])
        status = if result, do: result.status, else: :missing
        compare? = baseline != nil and run.id != baseline.id
        {run.id, cell(result, status, if(compare?, do: outcome(status, base), else: status))}
      end)

    %{case_id: c[:id], input: c[:input], cells: cells}
  end

  defp result_status(by_run, run_id, case_id) do
    case get_in(by_run, [run_id, case_id]) do
      nil -> :missing
      result -> result.status
    end
  end

  defp outcome(:passed, base) when base in [:failed, :errored], do: :improved
  defp outcome(status, :passed) when status in [:failed, :errored], do: :degraded
  defp outcome(status, _base), do: status

  defp cell(nil, status, outcome),
    do: %{status: status, outcome: outcome, result_id: nil, run_id: nil}

  defp cell(result, status, outcome),
    do: %{status: status, outcome: outcome, result_id: result.id, run_id: result.run_id}

  defp tally(quality, rows, id) do
    outcomes = Enum.map(rows, & &1.cells[id].outcome)
    count = fn wanted -> Enum.count(outcomes, &(&1 in List.wrap(wanted))) end
    passed = count.([:passed, :improved])
    measured = count.([:passed, :improved, :failed, :degraded, :errored])

    Map.merge(quality, %{
      passed: passed,
      improved: count.(:improved),
      degraded: count.(:degraded),
      failed: count.(:failed),
      errored: count.(:errored),
      skipped: count.(:skipped),
      unmeasured: count.(:unmeasured),
      missing: count.(:missing),
      rate: if(measured == 0, do: nil, else: passed / quality.cases)
    })
  end

  ## Safety

  defp safety(%{status: status}, _results, _cases, _injection, _missing) when status != :finished,
    do: {:not_measured, [:not_finished]}

  defp safety(_run, results, cases, injection, missing) do
    injection_results = Enum.map(injection, &Map.get(results, &1[:id]))

    case {failed(Map.values(results), injection_results),
          unknown(results, cases, injection_results, missing)} do
      {[_ | _] = failed, _unknown} -> {:failed, failed}
      {[], [_ | _] = unknown} -> {:not_measured, unknown}
      {[], []} -> {:clear, []}
    end
  end

  defp failed(measured, injection_results) do
    reasons([
      Enum.any?(measured, &hard_failure?/1) && :hard_failure,
      Enum.any?(measured, & &1.prohibited_effect_hit) && :prohibited_effect,
      Enum.any?(injection_results, &match?(%{status: :failed}, &1)) && :injection_failed
    ])
  end

  defp unknown(results, cases, injection_results, missing) do
    reasons([
      missing > 0 && :cases_missing,
      Enum.any?(injection_results, &(is_nil(&1) or &1.status != :passed)) &&
        :injection_not_measured,
      Enum.any?(cases, &hard_unmeasured?(&1, Map.get(results, &1[:id]))) && :hard_not_measured
    ])
  end

  defp reasons(flags), do: Enum.reject(flags, &(&1 == false))

  defp hard_failure?(result),
    do: Enum.any?(result.assertion_results, &(&1["hard"] == true and &1["status"] == "failed"))

  # A case with a hard assertion whose result does not show that assertion decided.
  defp hard_unmeasured?(c, result) do
    Enum.any?(c[:assertions] || [], &Assertions.hard?(&1.type)) and
      (is_nil(result) or result.status not in [:passed, :failed])
  end

  defp safety_rows(injection, runs, by_run, candidates) do
    by_id = Map.new(candidates, &{&1.id, &1})

    counts = fn key, count ->
      %{
        key: key,
        cells:
          Map.new(runs, fn run ->
            results = Map.values(Map.get(by_run, run.id, %{}))

            value =
              if run.status == :finished and results != [], do: Enum.count(results, count)

            {run.id, %{count: value}}
          end)
      }
    end

    [
      counts.(:hard_failures, &hard_failure?/1),
      counts.(:prohibited_effects, & &1.prohibited_effect_hit)
    ] ++
      Enum.map(injection, fn c ->
        %{
          key: :injection,
          case_id: c[:id],
          input: c[:input],
          cells:
            Map.new(runs, fn run ->
              result = get_in(by_run, [run.id, c[:id]])
              status = if result, do: result.status, else: :missing
              {run.id, cell(result, status, injection_outcome(result))}
            end)
        }
      end) ++
      [
        %{
          key: :verdict,
          cells: Map.new(runs, &{&1.id, Map.take(by_id[&1.id], [:safety, :safety_reasons])})
        }
      ]
  end

  defp injection_outcome(nil), do: :missing
  defp injection_outcome(%{status: :passed}), do: :held

  defp injection_outcome(%{status: :failed} = result) do
    if Enum.any?(result.assertion_results, &(&1["type"] in @attack and &1["status"] == "failed")),
      do: :attacked,
      else: :failed
  end

  defp injection_outcome(%{status: status}), do: status

  ## Recommended

  defp recommend(candidates) when length(candidates) < 2,
    do: {nil, :nothing_to_compare}

  defp recommend(candidates) do
    eligible = Enum.filter(candidates, &(&1.blocked == []))

    case Enum.sort_by(eligible, & &1.quality.rate, :desc) do
      [] -> {nil, :none_qualifies}
      [best, next | _] when best.quality.rate == next.quality.rate -> {nil, :tied}
      [best | _] -> {best.id, :recommended}
    end
  end

  @doc """
  Why the candidate does not qualify to be recommended: `[]` when it does. Each reason is
  one of `:not_finished`, `:imported`, `:safety_failed`, `:safety_not_measured`,
  `:cases_missing` and `:quality_not_measured`.
  """
  @spec blocked(map()) :: [atom()]
  def blocked(candidate) do
    Enum.reject(
      [
        candidate.status != :finished && :not_finished,
        candidate.imported && :imported,
        candidate.safety == :failed && :safety_failed,
        candidate.safety == :not_measured && :safety_not_measured,
        candidate.missing > 0 && :cases_missing,
        is_nil(candidate.quality[:rate]) && :quality_not_measured
      ],
      &(&1 == false)
    )
  end

  defp block(candidate), do: %{candidate | blocked: blocked(candidate)}
end
