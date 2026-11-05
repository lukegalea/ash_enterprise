defmodule AshEnterprise.Quality.Changes.CaseFromResult do
  @moduledoc """
  `add_case` of a suite, given a case result instead of a case ("save as case", the end
  of a prompt experiment): the `case` argument is made from what the result's case
  measured, and `add_case` carries on from there, so the suite checks it like any case.

  The new case, keyed by the `case_id` argument:

    * keeps the source case's `input`, `metadata` (with the values of its prompt
      variables), `fixtures`, `tags` and `assertions`, and records where it came from in
      `metadata["saved_from"]`;
    * takes the run's answer as its `target` (JSON-encoded unless it is text), or keeps
      the source case's;
    * is a `:dev` case: what an experiment saved is never held out of the next one.

  Everything is read as the person saving it, so a result they cannot read is refused as
  though it were not there. Giving both a `case` and a result, or neither, is refused.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Execution
  alias AshEnterprise.Quality.{CaseResult, Suite, SuiteRun}

  @impl true
  def change(changeset, _opts, context) do
    case {Ash.Changeset.get_argument(changeset, :case),
          Ash.Changeset.get_argument(changeset, :result_id)} do
      {nil, nil} ->
        Ash.Changeset.add_error(changeset,
          field: :case,
          message: "give a case, or a case result to save as one"
        )

      {_case, nil} ->
        changeset

      {nil, result_id} ->
        save(changeset, result_id, context)

      {_case, _result_id} ->
        Ash.Changeset.add_error(changeset,
          field: :result_id,
          message: "give a case or a case result, not both"
        )
    end
  end

  defp save(changeset, result_id, context) do
    opts = Ash.Context.to_opts(context, tenant: changeset.tenant)

    with {:ok, new_id} <- new_id(Ash.Changeset.get_argument(changeset, :case_id)),
         {:ok, result} <- Ash.get(CaseResult, result_id, opts),
         {:ok, suite_run} <- Ash.get(SuiteRun, result.suite_run_id, opts),
         {:ok, suite} <- Ash.get(Suite, suite_run.suite_id, opts),
         {:ok, source} <- source(suite, result.case_id) do
      Ash.Changeset.set_argument(changeset, :case, build(new_id, source, result, suite_run, opts))
    else
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  defp new_id(id) when is_binary(id) and id != "", do: {:ok, id}

  defp new_id(_none),
    do:
      {:error,
       Ash.Error.Changes.InvalidArgument.exception(
         field: :case_id,
         message: "is required to save a case result as a case"
       )}

  defp source(suite, case_id) do
    case Enum.find(suite.cases, &(&1[:id] == case_id)) do
      nil ->
        {:error,
         Ash.Error.Changes.InvalidArgument.exception(
           field: :result_id,
           message: "names a case its suite no longer holds"
         )}

      source ->
        {:ok, source}
    end
  end

  defp build(new_id, source, result, suite_run, opts) do
    %{
      id: new_id,
      input: source[:input],
      target: answer(result, opts) || source[:target],
      metadata:
        Map.put(source[:metadata] || %{}, "saved_from", %{
          "suite_run_id" => suite_run.id,
          "case_id" => result.case_id
        }),
      fixtures: source[:fixtures] || %{},
      split: :dev,
      tags: source[:tags] || [],
      assertions: source[:assertions] || []
    }
  end

  # The run's answer, when the person may read it and it has one.
  defp answer(%{run_id: nil}, _opts), do: nil

  defp answer(%{run_id: run_id}, opts) do
    case Execution.get_agent_run(run_id, [load: [:output]] ++ opts) do
      {:ok, %{output: %{"value" => text}}} when is_binary(text) -> text
      {:ok, %{output: %{"value" => value}}} when not is_nil(value) -> Jason.encode!(value)
      _none -> nil
    end
  end
end
