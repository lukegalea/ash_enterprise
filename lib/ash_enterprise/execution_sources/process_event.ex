defmodule AshEnterprise.ExecutionSources.ProcessEvent do
  @moduledoc """
  A process instance's history (`AshEnterprise.Bpmn.ProcessEvent`) as process-event
  entries under the instance: the instances the trace names, or that its runs and
  invocations belong to. An event that records a failure is failed, a cancellation
  cancelled, an event of a kind this source does not know uncertain, and every other
  event, which records that something happened, succeeded. Its data is never in its
  entry.
  """

  @behaviour AshAgent.Execution.Source

  alias AshAgent.Execution.Source
  alias AshEnterprise.ExecutionSources

  @failed [
    :action_failed,
    :escalation_failed,
    :instance_failed,
    :instance_errored,
    :signal_not_delivered,
    :task_expired
  ]
  @cancelled [:task_cancelled, :timer_cancelled, :instance_cancelled, :instance_terminated]
  @happened [
    :instance_started,
    :node_entered,
    :node_completed,
    :gateway_branch_taken,
    :task_created,
    :task_claimed,
    :task_delegated,
    :task_completed,
    :message_received,
    :signal_received,
    :condition_met,
    :timer_fired,
    :action_invoked,
    :instance_completed,
    :branch_completed,
    :child_started,
    :child_completed,
    :instance_superseded,
    :instance_restarted,
    :sweep_recovered,
    :condition_null,
    :activity_interrupted
  ]

  @impl true
  def read(scope, opts) do
    ExecutionSources.read(
      AshEnterprise.Bpmn.ProcessEvent,
      [instance_id: ExecutionSources.uuids(scope, :process_instance)],
      opts
    )
  end

  @impl true
  def to_entries(rows), do: Enum.map(rows, &entry/1)

  defp entry(event) do
    Source.entry(
      at: event.created_on,
      kind: :process_event,
      status: status(event.kind),
      source_ref: Source.ref(:process_event, event.id),
      parent_ref: Source.ref(:process_instance, event.instance_id),
      summary: Enum.join(Enum.reject([event.kind, event.node_id], &is_nil/1), " ")
    )
  end

  @doc false
  def status(kind) when kind in @failed, do: :failed
  def status(kind) when kind in @cancelled, do: :cancelled
  def status(kind) when kind in @happened, do: :succeeded
  def status(_unknown), do: :uncertain
end
