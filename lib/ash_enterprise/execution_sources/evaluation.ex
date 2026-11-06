defmodule AshEnterprise.ExecutionSources.Evaluation do
  @moduledoc """
  Decision evaluations (`AshEnterprise.Decisions.Evaluation`) as decision entries: the
  evaluations recorded under the trace's correlation id, each with the definition
  version that decided (`key@version`) and the rules that matched. An evaluation that
  recorded an error failed. Its inputs and outputs are never in its entry.
  """

  @behaviour AshAgent.Execution.Source

  alias AshAgent.Execution.Source
  alias AshEnterprise.ExecutionSources

  @impl true
  def read(scope, opts) do
    ExecutionSources.read(
      AshEnterprise.Decisions.Evaluation,
      [correlation_id: ExecutionSources.correlation(scope)],
      opts
    )
  end

  @impl true
  def to_entries(rows), do: Enum.map(rows, &entry/1)

  defp entry(evaluation) do
    Source.entry(
      at: evaluation.created_on,
      kind: :decision,
      status: if(evaluation.error in [nil, %{}], do: :succeeded, else: :failed),
      source_ref: Source.ref(:evaluation, evaluation.id),
      definition_ref: "#{evaluation.definition_key}@#{evaluation.definition_version}",
      cost: evaluation.duration_us && %{duration_ms: div(evaluation.duration_us, 1000)},
      summary: summary(evaluation)
    )
  end

  defp summary(%{matched_rule_ids: [_ | _] = rules} = evaluation),
    do: "#{evaluation.decision_id || evaluation.definition_key}: rules #{Enum.join(rules, ", ")}"

  defp summary(evaluation),
    do: "#{evaluation.decision_id || evaluation.definition_key}: no rule matched"
end
