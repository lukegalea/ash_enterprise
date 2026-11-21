defmodule AshEnterprise.Quality.Changes.RecordJudged do
  @moduledoc """
  A finished suite run's `record_judged`: its judged scores and report recomputed from
  the admitted facts (`AshEnterprise.Quality.Evaluation.scores/3`), with the `grading`
  argument as the report's `"grading"`. Sets `summary["judged"]` and rewrites each case
  result's `scores` (`AshEnterprise.Quality.CaseResult`'s `record_scores`) in the same
  transaction. Calls no model: `AshEnterprise.Quality.SuiteRun.GradeWorker` grades
  first, then runs it. Nothing else in the summary or the case results changes, so
  neither the suite gate nor the release gate reads anything new (ADR 0058, D9).
  """

  use Ash.Resource.Change

  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Quality
  alias AshEnterprise.Quality.Evaluation

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&score/1)
    |> Ash.Changeset.after_action(&record/2)
  end

  defp score(changeset) do
    suite_run = changeset.data
    tenant = changeset.tenant
    grading = Ash.Changeset.get_argument(changeset, :grading)

    judged =
      suite_run
      |> Evaluation.replies(Evaluation.suite(suite_run, tenant), tenant)
      |> Evaluation.scores(grading, tenant)

    changeset
    |> Ash.Changeset.force_change_attribute(
      :summary,
      Map.put(suite_run.summary || %{}, "judged", judged.report)
    )
    |> Ash.Changeset.set_context(%{quality: %{scores: judged.scores}})
  end

  defp record(changeset, suite_run) do
    opts = [actor: SystemActor.oban(), tenant: changeset.tenant]
    scores = changeset.context.quality.scores

    [query: [filter: [suite_run_id: suite_run.id]]]
    |> Kernel.++(opts)
    |> Quality.list_case_results!()
    |> Enum.reduce_while({:ok, suite_run}, fn result, ok ->
      case Quality.record_case_result_scores(result, Map.get(scores, result.case_id, []), opts) do
        {:ok, _result} -> {:cont, ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end
end
