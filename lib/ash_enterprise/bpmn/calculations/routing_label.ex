defmodule AshEnterprise.Bpmn.Calculations.RoutingLabel do
  @moduledoc """
  For a task whose candidates, minus its exclusions, left nobody, says what happened instead:
  `No eligible reviewer: escalated to the fallback (2).` or `No eligible reviewer, and no
  fallback: nobody can act on this task.` Nil for every other task.

  Read from the engine's `:no_eligible_candidate` events for the tasks being shown, in one
  query per batch, as the system in the reader's tenant: the reader already reads these
  tasks, and the event says only how the task was routed, which is what the label shows.
  """

  use Ash.Resource.Calculation

  require Ash.Query

  alias AshEnterprise.Bpmn.ProcessEvent

  @impl true
  def load(_query, _opts, _context), do: [:id]

  @impl true
  def calculate(tasks, _opts, context) do
    events = events(Enum.map(tasks, & &1.id), context)
    {:ok, Enum.map(tasks, &label(Map.get(events, &1.id)))}
  end

  defp events([], _context), do: %{}

  defp events(task_ids, context) do
    ProcessEvent
    |> Ash.Query.filter(task_id in ^task_ids and kind == :no_eligible_candidate)
    |> Ash.read!(authorize?: false, tenant: context.tenant)
    |> Map.new(&{&1.task_id, &1.data || %{}})
  end

  defp label(nil), do: nil

  defp label(%{"escalated" => true} = data),
    do: "No eligible reviewer: escalated to the fallback (#{data["fallback"] || 0})."

  defp label(_data), do: "No eligible reviewer, and no fallback: nobody can act on this task."
end
