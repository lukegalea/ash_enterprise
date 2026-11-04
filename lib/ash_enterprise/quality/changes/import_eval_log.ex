defmodule AshEnterprise.Quality.Changes.ImportEvalLog do
  @moduledoc """
  A suite run's `import_eval_log`: records the results of an Inspect EvalLog
  (`AshEnterprise.Quality.Interchange.EvalLog`) as a finished suite run of a published
  suite, in one transaction.

  Every sample must be a case of the suite: a log of another dataset is refused, naming
  the ids. The run is marked `imported`, carries no `candidate_digest` and measured the
  suite as it stands (`suite_content_hash`): it cannot stand for a candidate a release
  gate names. Its summary is scored as a finish scores one, and keeps the judged report
  the log carried.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Quality.Changes.{Finish, RecordResults}
  alias AshEnterprise.Quality.Interchange.EvalLog
  alias AshEnterprise.Quality.Suite

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> Ash.Changeset.before_action(&read(&1, context))
    |> Ash.Changeset.after_action(fn changeset, suite_run ->
      RecordResults.record(suite_run, changeset.context.quality.results, changeset.tenant)
    end)
  end

  defp read(changeset, context) do
    log = Ash.Changeset.get_argument(changeset, :log)
    suite_id = Ash.Changeset.get_attribute(changeset, :suite_id)

    with {:ok, %{results: results, judged: judged}} <- EvalLog.parse(log),
         {:ok, %Suite{status: :published} = suite} <-
           Ash.get(Suite, suite_id, Ash.Context.to_opts(context, tenant: changeset.tenant)),
         :ok <- known(results, suite) do
      summary = Finish.summary(suite.cases, results) |> put_judged(judged)

      changeset
      |> Ash.Changeset.force_change_attributes(%{
        status: :finished,
        imported: true,
        suite_content_hash: suite.content_hash,
        summary: summary,
        finished_at: DateTime.utc_now()
      })
      |> Ash.Changeset.set_context(%{quality: %{results: results}})
    else
      {:ok, %Suite{status: status}} ->
        Ash.Changeset.add_error(changeset,
          field: :suite_id,
          message: "is %{status}; only a published suite takes results",
          vars: [status: status]
        )

      {:error, message} when is_binary(message) ->
        Ash.Changeset.add_error(changeset, field: :log, message: message)

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp known(results, suite) do
    ids = MapSet.new(suite.cases, & &1[:id])

    case results |> Enum.map(& &1.case_id) |> Enum.reject(&MapSet.member?(ids, &1)) do
      [] -> :ok
      unknown -> {:error, "not cases of the suite: " <> Enum.join(Enum.uniq(unknown), ", ")}
    end
  end

  defp put_judged(summary, nil), do: summary
  defp put_judged(summary, judged), do: Map.put(summary, "judged", judged)
end
