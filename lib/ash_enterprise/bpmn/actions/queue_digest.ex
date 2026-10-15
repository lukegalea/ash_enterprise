defmodule AshEnterprise.Bpmn.Actions.QueueDigest do
  @moduledoc """
  `HumanTask.queue_digest`: the tasks waiting on the actor as a numbered list,
  for a terminal transcript (the ACP `approvals` prompt). The numbers are the
  positions `approve N` / `reject N` resolve against — same read, same order.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Platform.LocalTime

  @impl true
  def run(_input, _opts, context) do
    opts = Ash.Context.to_opts(context)

    case awaiting(opts) do
      {:ok, tasks} -> {:ok, render(tasks)}
      {:error, error} -> {:error, error}
    end
  end

  @doc "The tasks waiting on the actor in `opts`, oldest first."
  def awaiting(opts) do
    HumanTask
    |> Ash.Query.for_read(:awaiting_me, %{}, opts)
    |> Ash.Query.load([:subject_label])
    |> Ash.read(opts)
  end

  @doc false
  def render([]), do: "Approvals — nothing is waiting on you."

  def render(tasks) do
    lines =
      tasks
      |> Enum.with_index(1)
      |> Enum.map(fn {task, n} ->
        "  #{n}. #{task.name} — #{task.subject_label}  · #{task.status}  · since #{LocalTime.stamp(task.inserted_at)}"
      end)

    Enum.join(
      ["Approvals — #{length(tasks)} waiting on you. Say `approve N` or `reject N`." | lines],
      "\n"
    )
  end
end
