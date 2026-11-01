defmodule AshEnterprise.Assistant.Lookups.Tasks do
  @moduledoc """
  `Lookup.Task.my_tasks`: the person's own tasks and action items
  (`Canonical.Task`, quick-captured or projected), soonest due first, as
  `Task.read` returns them to that person. At most #{30}.
  """

  use Ash.Resource.ManualRead

  require Ash.Query

  alias AshEnterprise.Assistant.Lookup
  alias AshEnterprise.Assistant.Lookups.Support
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Platform.LocalTime

  @shown 30

  @impl true
  def read(query, _data_layer_query, _opts, context) do
    Support.gated(query, context, fn opts ->
      Task
      |> Ash.Query.for_read(:read, %{}, opts)
      |> by_status(query.arguments[:status] || :open)
      |> Ash.Query.sort(due_at: :asc_nils_last, inserted_at: :desc)
      |> Ash.Query.load(:label)
      |> Ash.Query.limit(@shown)
      |> Ash.read(opts)
      |> case do
        {:ok, tasks} -> {:ok, Enum.map(tasks, &row/1)}
        error -> error
      end
    end)
  end

  defp by_status(query, :any), do: query
  defp by_status(query, status), do: Ash.Query.filter(query, status == ^status)

  defp row(task) do
    Support.row(Lookup.Task, %{
      id: task.id,
      title: Support.clip(task.label, 200),
      status: task.status,
      due: task.due_at && LocalTime.stamp(task.due_at),
      source: task.source
    })
  end
end
