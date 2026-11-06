defmodule AshEnterprise.ExecutionSources.ProcessInstance do
  @moduledoc """
  Process runs (`AshEnterprise.Bpmn.Instance`) as execution entries: one logical
  operation per run, with the definition it pinned (`key@version`). Reads the runs
  recorded under the trace's correlation id (the request that started them) or named by
  it, so a trace of the request reaches the process's events, tasks and service calls.

  A running instance is running; a completed one succeeded; a failed or errored one
  failed; a cancelled or superseded one was cancelled; any other status is uncertain.
  """

  @behaviour AshAgent.Execution.Source

  alias AshAgent.Execution.Source
  alias AshEnterprise.Bpmn.{Definition, Instance}
  alias AshEnterprise.ExecutionSources
  alias AshEnterprise.Process.DefinitionLoader

  @impl true
  def read(scope, opts) do
    with {:ok, rows, next} <-
           ExecutionSources.read(
             Instance,
             [
               correlation_id: ExecutionSources.correlation(scope),
               id: ExecutionSources.uuids(scope, :process_instance)
             ],
             opts
           ) do
      {:ok, Enum.map(rows, &Ash.Resource.put_metadata(&1, :definition, definition(&1))), next}
    end
  end

  # The definition is configuration, not data about anyone, and a run usually pins a
  # platform baseline a tenant read cannot see: it is found the way the engine finds it.
  defp definition(instance) do
    case DefinitionLoader.load(Definition, instance.definition_id, instance, %{
           tenant: instance.organization_id
         }) do
      {:ok, definition} -> "#{definition.key}@#{definition.version}"
      {:error, _not_found} -> nil
    end
  end

  @impl true
  def to_entries(rows), do: Enum.map(rows, &entry/1)

  defp entry(instance) do
    Source.entry(
      at: instance.created_on,
      kind: :logical_operation,
      status: status(instance.status),
      source_ref: Source.ref(:process_instance, instance.id),
      parent_ref:
        instance.parent_instance_id &&
          Source.ref(:process_instance, instance.parent_instance_id),
      definition_ref: instance.__metadata__[:definition],
      actor_label: ExecutionSources.person_label(instance.started_by_id),
      summary: summary(instance)
    )
  end

  @doc false
  def status(:running), do: :running
  def status(:completed), do: :succeeded
  def status(:failed), do: :failed
  def status(:errored), do: :failed
  def status(:cancelled), do: :cancelled
  def status(:superseded), do: :cancelled
  def status(_unknown), do: :uncertain

  defp summary(%{outcome: outcome} = instance) when is_binary(outcome),
    do: "process run (#{instance.status}): #{outcome}"

  defp summary(instance), do: "process run (#{instance.status})"
end
