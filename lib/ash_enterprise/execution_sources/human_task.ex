defmodule AshEnterprise.ExecutionSources.HumanTask do
  @moduledoc """
  Tasks for a person (`AshEnterprise.Bpmn.HumanTask`) as approval entries: an
  invocation's approval task under its invocation, a process's user task under its
  instance. Reads the tasks named by the trace, opened for one of its invocations, or
  in one of its process instances.

  An open task waits on a person; a claimed one is running; a completed one succeeded,
  unless it was rejected (cancelled) or expired (failed); a cancelled one is cancelled.
  Its comment is never in its entry.
  """

  @behaviour AshAgent.Execution.Source

  alias AshAgent.Execution.Source
  alias AshEnterprise.ExecutionSources

  @invocation to_string(AshEnterprise.Execution.Invocation)

  @impl true
  def read(scope, opts) do
    ExecutionSources.read(
      AshEnterprise.Bpmn.HumanTask,
      [
        id: ExecutionSources.uuids(scope, :human_task),
        subject_id: ExecutionSources.uuids(scope, :invocation),
        instance_id: ExecutionSources.uuids(scope, :process_instance)
      ],
      opts
    )
  end

  @impl true
  def to_entries(rows), do: Enum.map(rows, &entry/1)

  defp entry(task) do
    {status, blocked_on} = status(task)

    Source.entry(
      at: task.created_on,
      kind: :approval,
      status: status,
      blocked_on: blocked_on,
      source_ref: Source.ref(:human_task, task.id),
      parent_ref: parent(task),
      actor_label: ExecutionSources.person_label(task.decided_by_id),
      summary: summary(task)
    )
  end

  @doc false
  def status(%{status: :open}), do: {:waiting, :human}
  def status(%{status: :claimed}), do: {:running, nil}
  def status(%{status: :completed, outcome: "rejected"}), do: {:cancelled, nil}
  def status(%{status: :completed, outcome: "expired"}), do: {:failed, nil}

  def status(%{status: :completed, outcome: outcome}) when is_binary(outcome),
    do: {:succeeded, nil}

  def status(%{status: :cancelled}), do: {:cancelled, nil}
  def status(_unknown), do: {:uncertain, nil}

  defp parent(%{subject_type: @invocation, subject_id: id}) when is_binary(id),
    do: Source.ref(:invocation, id)

  defp parent(%{instance_id: id}) when is_binary(id), do: Source.ref(:process_instance, id)
  defp parent(_task), do: nil

  defp summary(%{outcome: outcome} = task) when is_binary(outcome),
    do: "#{task.name || task.node_id}: #{outcome}"

  defp summary(task), do: "#{task.name || task.node_id}: #{task.status}"
end
