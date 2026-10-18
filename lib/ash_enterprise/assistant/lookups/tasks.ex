defmodule AshEnterprise.Assistant.Lookups.Tasks do
  @moduledoc """
  `Lookup.my_tasks`: the person's own tasks and action items
  (`Canonical.Task`, quick-captured or projected), soonest due first, as
  `Task.read` returns them to that person. At most #{30}.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias AshEnterprise.Assistant.Lookups.Support
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Platform.LocalTime

  @shown 30

  @impl true
  def run(input, _opts, context) do
    Support.gated(input, context, fn opts ->
      Task
      |> Ash.Query.for_read(:read, %{}, opts)
      |> by_status(input.arguments[:status] || :open)
      |> Ash.Query.sort(due_at: :asc_nils_last, inserted_at: :desc)
      |> Ash.Query.limit(@shown + 1)
      |> Ash.read(opts)
      |> case do
        {:ok, tasks} ->
          {:ok,
           %{
             "count" => min(length(tasks), @shown),
             "more" => length(tasks) > @shown,
             "tasks" => tasks |> Enum.take(@shown) |> Enum.map(&row/1)
           }}

        error ->
          error
      end
    end)
  end

  defp by_status(query, :any), do: query
  defp by_status(query, status), do: Ash.Query.filter(query, status == ^status)

  defp row(task) do
    %{
      "id" => task.id,
      "title" => Support.clip(task.title, 200),
      "status" => task.status,
      "due" => task.due_at && LocalTime.stamp(task.due_at),
      "source" => task.source
    }
    |> Support.compact()
  end
end
