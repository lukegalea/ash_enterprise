defmodule AshEnterprise.ExecutionSources.CaseResult do
  @moduledoc """
  Evaluation case results (`AshEnterprise.Quality.CaseResult`) as observation entries
  under the run they graded: the results of the trace's runs. A case that passed
  succeeded; one that failed or errored failed; a skipped case was cancelled; and an
  unmeasured case is uncertain: a missing measurement is never a pass.
  """

  @behaviour AshAgent.Execution.Source

  alias AshAgent.Execution.Source
  alias AshEnterprise.ExecutionSources

  @impl true
  def read(scope, opts) do
    ExecutionSources.read(
      AshEnterprise.Quality.CaseResult,
      [run_id: ExecutionSources.uuids(scope, :run)],
      opts
    )
  end

  @impl true
  def to_entries(rows), do: Enum.map(rows, &entry/1)

  defp entry(result) do
    Source.entry(
      at: result.created_on,
      kind: :observation,
      status: status(result.status),
      source_ref: Source.ref(:case_result, result.id),
      parent_ref: result.run_id && Source.ref(:run, result.run_id),
      definition_ref: result.case_id,
      summary: "case #{result.case_id}: #{result.status}"
    )
  end

  @doc false
  def status(:passed), do: :succeeded
  def status(:failed), do: :failed
  def status(:errored), do: :failed
  def status(:skipped), do: :cancelled
  def status(_unmeasured_or_unknown), do: :uncertain
end
