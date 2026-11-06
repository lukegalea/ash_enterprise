defmodule AshEnterprise.ExecutionSources.Run do
  @moduledoc """
  Agent runs (`AshEnterprise.Execution.Run`) as execution entries: one logical operation
  per run, under the process instance that started it, if one did. Reads the runs
  recorded under the trace's correlation id, named by it, or started by one of its
  process instances.
  """

  @behaviour AshAgent.Execution.Source

  alias AshAgent.Execution.{Source, Status}
  alias AshEnterprise.ExecutionSources

  @impl true
  def read(scope, opts) do
    ExecutionSources.read(
      AshEnterprise.Execution.Run,
      [
        correlation_id: ExecutionSources.correlation(scope),
        id: ExecutionSources.uuids(scope, :run),
        process_instance_id: ExecutionSources.uuids(scope, :process_instance)
      ],
      opts
    )
  end

  @impl true
  def to_entries(rows), do: Enum.map(rows, &entry/1)

  defp entry(run) do
    {status, blocked_on} = Status.run(run)

    Source.entry(
      at: run.created_on,
      kind: :logical_operation,
      status: status,
      blocked_on: blocked_on,
      source_ref: Source.ref(:run, run.id),
      parent_ref:
        run.process_instance_id && Source.ref(:process_instance, run.process_instance_id),
      definition_ref: "#{run.agent_key}@#{run.agent_version_id}",
      actor_label: ExecutionSources.principal_label(run.executing_principal),
      cost: %{tokens: run.budget_spent},
      summary: summary(run)
    )
  end

  defp summary(%{error_code: code} = run) when is_binary(code),
    do: "run of #{run.agent_key} (#{run.mode}): #{code}"

  defp summary(run), do: "run of #{run.agent_key} (#{run.mode})"
end
