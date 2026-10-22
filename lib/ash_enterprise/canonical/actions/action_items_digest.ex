defmodule AshEnterprise.Canonical.Actions.ActionItemsDigest do
  @moduledoc """
  The ACP `todo` prompts (`Console.action_items`, `.todo`, `.done`): the
  actor's action items as a numbered list for a terminal transcript, quick
  capture, and finishing one.

    * `op: :list` — open items numbered Today, then Inbox, then Later
      (soonest due first in each), and how many process tasks wait on the
      actor. The numbers are what `done N` resolves against
      (`AshEnterprise.Acp.Commands`, through `items/1`): same read, same
      order.
    * `op: :capture` — `Task.capture` as the actor, `source: :acp`, into
      their Inbox.
    * `op: :done` — `Task.complete_mine` as the actor on the item the prompt
      named.

  Every read and write runs as the actor under its own policies: the list is
  `Task.mine` (self-service, owner-only, ADR 0052) and the writes are the
  task's self-service actions, so nothing here reaches a row the actor does
  not own.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Bpmn.Actions.QueueDigest
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Platform.LocalTime

  @lanes [today: "Today", inbox: "Inbox", later: "Later"]
  @rank %{today: 0, inbox: 1, later: 2}

  @impl true
  def run(input, opts, context) do
    ash_opts =
      context
      |> Ash.Context.to_opts()
      |> Keyword.take([:actor, :tenant, :tracer])
      |> Keyword.put(:authorize?, true)

    case Keyword.fetch!(opts, :op) do
      :list -> list(ash_opts)
      :capture -> capture(input.arguments.text, ash_opts)
      :done -> done(input.arguments.record_id, ash_opts)
    end
  end

  @doc "The actor's open action items in list order: Today, Inbox, Later."
  @spec items(keyword()) :: {:ok, [Task.t()]} | {:error, term()}
  def items(opts) do
    with {:ok, tasks} <-
           Task.mine(Keyword.merge(opts, query: [filter: [status: :open]], load: [:label])) do
      ordered =
        tasks
        |> Enum.with_index()
        |> Enum.sort_by(fn {task, i} -> {Map.fetch!(@rank, task.plan), i} end)
        |> Enum.map(&elem(&1, 0))

      {:ok, ordered}
    end
  end

  defp list(opts) do
    with {:ok, tasks} <- items(opts), do: {:ok, render(tasks, waiting(opts))}
  end

  @doc false
  def render([], waiting),
    do: "Action items — nothing open. Say `todo <text>` to capture one.\n#{waiting}"

  def render(tasks, waiting) do
    numbered = Enum.with_index(tasks, 1)

    sections =
      for {plan, label} <- @lanes,
          rows = for({task, n} <- numbered, task.plan == plan, do: line(task, n)),
          rows != [],
          do: Enum.join([label | rows], "\n")

    header =
      "Action items — #{length(tasks)} open. Say `done N` to finish one, `todo <text>` to capture one."

    Enum.join([header | sections] ++ [waiting], "\n")
  end

  defp line(%Task{due_at: nil} = task, n), do: "  #{n}. #{task.label}"
  defp line(task, n), do: "  #{n}. #{task.label}  · due #{LocalTime.stamp(task.due_at)}"

  defp waiting(opts) do
    case QueueDigest.awaiting(opts) do
      {:ok, []} -> "Waiting on you: nothing."
      {:ok, [_]} -> "Waiting on you: 1 process task — say `approvals`."
      {:ok, tasks} -> "Waiting on you: #{length(tasks)} process tasks — say `approvals`."
      {:error, _} -> "Waiting on you: unavailable."
    end
  end

  defp capture(text, opts) do
    title = text |> to_string() |> String.trim()

    with {:ok, _task} <- Task.capture(title, %{source: :acp}, opts) do
      {:ok, "Captured into your Inbox: #{title}\nSay `todo` to see the list."}
    end
  end

  defp done(record_id, opts) do
    with {:ok, task} <- Task.complete_mine(record_id, opts),
         {:ok, task} <- Ash.load(task, :label, opts),
         do: {:ok, "Done: #{task.label}"}
  end
end
