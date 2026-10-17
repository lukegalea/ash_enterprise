defmodule AshEnterprise.Assistant.Lookups.Approvals do
  @moduledoc """
  `Lookup.pending_approvals`: the process tasks the person can act on —
  open or claimed tasks they (or a team of theirs) are a candidate for, or
  hold — oldest first, through `HumanTask.awaiting_me` as that person. The
  same read the Approvals surface and the ACP `approvals` prompt use. Reads
  only: deciding a task stays the human's act on the surface.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Assistant.Lookups.Support
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Platform.LocalTime

  @shown 25

  @impl true
  def run(input, _opts, context) do
    Support.gated(input, context, fn opts ->
      HumanTask
      |> Ash.Query.for_read(:awaiting_me, %{}, opts)
      |> Ash.Query.load([:subject_label, :subject_outline, :waiting_since])
      |> Ash.read(opts)
      |> case do
        {:ok, tasks} ->
          {:ok,
           %{
             "count" => length(tasks),
             "approvals" => tasks |> Enum.take(@shown) |> Enum.map(&row/1)
           }}

        error ->
          error
      end
    end)
  end

  defp row(task) do
    %{
      "ref" => Support.ref(HumanTask, task),
      "task" => task.name,
      "about" => Support.text(task.subject_label),
      "outline" => Support.text(task.subject_outline),
      "status" => task.status,
      "waiting_since" => Support.text(task.waiting_since),
      "due" => task.due_at && LocalTime.stamp(task.due_at)
    }
    |> Support.compact()
  end
end
