defmodule AshEnterprise.Quality.SuiteRun.GradeWorker do
  @moduledoc """
  Grades the answers of a suite run that finished in the evaluation tenant
  (`AshEnterprise.Quality.Evaluation`), then records its judged scores again from the
  facts that grading admitted. `AshEnterprise.Quality.Changes.Finish` enqueues it, in
  the transaction that finishes the run, for a suite naming the judged scorer.

  Model-bound work, so it runs on `:system_one`, never in a read, a calculation or a
  policy check.

    1. **The tenant.** Its answers are graded only if the job's tenant is the
       evaluation tenant when the job runs. If the designation moved, nothing is graded:
       the scores are recorded unknown for that reason and the job is cancelled.
    2. **The instrument.** Its identity is read once (`Evaluation.instrument/0`). If it
       cannot be read nothing is judged: `"grading"` records `"failed"` and the job
       fails, to try again.
    3. **Grade.** Each case's text answer goes through
       `AshEnterprise.Quality.Grader.grade/2`: judge, band and admit, as the `oban`
       system actor. A case with no text answer is not judged.
    4. **Record.** `record_judged` recomputes the scores and the report from the
       admitted facts, with `"grading"`: `"graded"`, the pairs judged this time and the
       model errors among them. A model error admits nothing, so that pair stays
       unknown; the job then fails, so a retry asks those pairs again.

  Idempotent (iron law #07): only one job per suite run waits or runs at a time
  (`unique` on `suite_run_id`), and a pair with a current fact, or whose unchanged text
  was already judged and banded, is never judged again (`Grader.grade/2`), so a re-run
  records no second judgment. Its args are the suite run's id and tenant, string-keyed
  (#08, #09).
  """

  use Oban.Worker,
    queue: :system_one,
    max_attempts: 3,
    unique: [period: :infinity, keys: [:suite_run_id], states: :incomplete]

  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Quality
  alias AshEnterprise.Quality.{AgentReply, Evaluation, Grader}

  @doc "The job args for `suite_run`."
  @spec args(map()) :: %{String.t() => Ash.UUID.t()}
  def args(suite_run),
    do: %{"suite_run_id" => suite_run.id, "tenant" => suite_run.organization_id}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"suite_run_id" => id, "tenant" => tenant}}) do
    with {:ok, suite_run} <- Quality.get_suite_run(id, actor: SystemActor.oban(), tenant: tenant) do
      run(suite_run, tenant, Evaluation.designation(tenant))
    end
  end

  defp run(suite_run, tenant, :evaluation_tenant),
    do: grade(suite_run, tenant, Evaluation.instrument())

  defp run(suite_run, tenant, {:not_graded, reason}),
    do: finish(record(suite_run, Evaluation.not_graded_entry(reason), tenant), {:cancel, reason})

  defp grade(suite_run, tenant, {:ok, instrument}) do
    entries =
      suite_run
      |> Evaluation.replies(Evaluation.suite(suite_run, tenant), tenant)
      |> Enum.filter(&match?(%AgentReply{}, &1))
      |> Grader.grade(
        [tenant: tenant, instrument: instrument, actor: SystemActor.oban()] ++
          Evaluation.grader_opts()
      )

    errors = Enum.count(entries, &is_nil(&1.observation_id))

    grading = %{
      "status" => "graded",
      "judged" => Enum.count(entries, &(&1.result != {:skipped, :already_banded})),
      "judge_errors" => errors
    }

    outcome =
      if errors == 0,
        do: :ok,
        else: {:error, "#{errors} judge error(s): those pairs read unknown"}

    finish(record(suite_run, grading, tenant), outcome)
  end

  # The reason can carry the runtime's address; the job's error does not.
  defp grade(suite_run, tenant, {:error, _reason}) do
    suite_run
    |> record(%{"status" => "failed", "reason" => "instrument_unavailable"}, tenant)
    |> finish({:error, :instrument_unavailable})
  end

  defp finish({:ok, _suite_run}, outcome), do: outcome
  defp finish({:error, _error} = error, _outcome), do: error

  defp record(suite_run, grading, tenant),
    do:
      Quality.record_suite_run_judged(suite_run, grading,
        actor: SystemActor.oban(),
        tenant: tenant
      )
end
