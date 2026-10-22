defmodule AshEnterprise.Canonical.Calculations.TaskDue do
  @moduledoc """
  A task's due time on the operator's wall clock
  (`AshEnterprise.Platform.LocalTime`): `Mon 12 Oct 17:00`, with
  `· overdue` appended while an open task is past it. Nil when the task has
  no due date. Display-only — sort and filter on `due_at`.
  """

  use Ash.Resource.Calculation

  alias AshEnterprise.Platform.LocalTime

  @impl true
  def load(_query, _opts, _context), do: [:due_at, :status]

  @impl true
  def calculate(tasks, _opts, _context) do
    now = DateTime.utc_now()
    {:ok, Enum.map(tasks, &due(&1, now))}
  end

  defp due(%{due_at: nil}, _now), do: nil

  defp due(%{due_at: due_at, status: :open}, now) do
    if DateTime.compare(due_at, now) == :lt,
      do: "#{LocalTime.stamp(due_at)} · overdue",
      else: LocalTime.stamp(due_at)
  end

  defp due(%{due_at: due_at}, _now), do: LocalTime.stamp(due_at)
end
