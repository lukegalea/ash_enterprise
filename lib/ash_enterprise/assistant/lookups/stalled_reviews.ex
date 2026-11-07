defmodule AshEnterprise.Assistant.Lookups.StalledReviews do
  @moduledoc """
  `Lookup.StalledReview.stalled_reviews`: `HumanTask.stalled` (open or claimed tasks
  that opened more than two days ago, oldest first) as the person reads it, the
  oldest #{25} listed with a ref each, how many there are, and the same read composed
  for the person's screen (`AshEnterprise.Assistant.Composer`, `"stalled_reviews"`),
  which the page renders in the answer as it renders `compose_surface`'s.

  The view is also a declared surface, `/app/reviews/stalled`, reached without chat.
  """

  use Ash.Resource.ManualRead

  alias AshEnterprise.Assistant.Composer
  alias AshEnterprise.Assistant.Lookup.StalledReview
  alias AshEnterprise.Assistant.Lookups.Support
  alias AshEnterprise.Bpmn.HumanTask

  @shown 25
  @page "/app/reviews/stalled"

  @impl true
  def read(query, _data_layer_query, _opts, context) do
    Support.gated(query, context, fn opts ->
      stalled = Ash.Query.for_read(HumanTask, :stalled, %{}, opts)

      with {:ok, count} <- Ash.count(stalled, opts),
           {:ok, tasks} <-
             stalled
             |> Ash.Query.load([:subject_label, :waiting_since, :assignee_label])
             |> Ash.Query.limit(@shown)
             |> Ash.read(opts),
           {:ok, composed} <- compose() do
        {:ok,
         [
           Support.row(StalledReview, %{
             shown: composed.title,
             count: count,
             reviews: Enum.map(tasks, &review/1),
             surface: composed.request,
             page: @page,
             note: note(count)
           })
         ]}
      end
    end)
  end

  defp compose do
    case Composer.compose(%{show: "stalled_reviews", title: "Reviews waiting over two days"}) do
      {:ok, composed} -> {:ok, composed}
      {:error, reasons} -> {:error, "Not shown: " <> Enum.join(reasons, "; ")}
    end
  end

  defp review(task) do
    %{
      ref: Support.ref(HumanTask, task),
      task: task.name,
      about: Support.text(task.subject_label),
      status: task.status,
      waiting_since: Support.text(task.waiting_since),
      claimed_by: Support.text(task.assignee_label)
    }
    |> Map.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp note(0),
    do:
      "None of the tasks this person may read has waited more than two days. Say so; the " <>
        "view on screen is empty."

  defp note(count) when count > @shown,
    do:
      "The view on screen lists all #{count}; only the oldest #{@shown} are listed here. " <>
        "Say how many there are and cite the oldest; do not list every row."

  defp note(_count),
    do:
      "The view is on the person's screen now, read as them, and at #{@page}. Say how many " <>
        "there are and cite the oldest; do not list every row."
end
