defmodule AshEnterprise.ExecutionSources.Judgment do
  @moduledoc """
  The judgment ledger (`AshEnterprise.SystemOne.Judgment`) as observation entries: the
  judgments recorded under the trace's correlation id, or for one of its runs or
  invocations, each with its question (`question@version`) and the kind of answer. The
  judged text is sealed and the answer stays in the ledger: neither is in an entry. A
  judgment whose judged text was erased is not recorded.
  """

  @behaviour AshAgent.Execution.Source

  alias AshAgent.Execution.Source
  alias AshEnterprise.ExecutionSources

  @impl true
  def read(scope, opts) do
    ExecutionSources.read(
      AshEnterprise.SystemOne.Judgment,
      [
        # The ledger's correlation id is a UUID.
        correlation_id:
          for(
            id <- ExecutionSources.correlation(scope),
            {:ok, uuid} <- [Ecto.UUID.cast(id)],
            do: uuid
          ),
        run_id: Source.ids(scope, :run),
        invocation_id: Source.ids(scope, :invocation)
      ],
      opts
    )
  end

  @impl true
  def to_entries(rows), do: Enum.map(rows, &entry/1)

  defp entry(judgment) do
    Source.entry(
      at: judgment.created_on,
      kind: :observation,
      status: :succeeded,
      source_ref: Source.ref(:judgment, judgment.id),
      parent_ref: parent(judgment),
      definition_ref: "#{judgment.question_id}@#{judgment.question_version}",
      actor_label: judgment.model_spec_requested,
      recorded?: not is_nil(judgment.state_ciphertext),
      summary: "#{judgment.question_id}: #{judgment.answer_kind} answer"
    )
  end

  defp parent(%{invocation_id: id}) when is_binary(id), do: Source.ref(:invocation, id)
  defp parent(%{run_id: id}) when is_binary(id), do: Source.ref(:run, id)
  defp parent(_judgment), do: nil
end
