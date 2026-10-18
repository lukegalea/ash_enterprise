defmodule AshEnterprise.Assistant.Lookups.Approvals do
  @moduledoc """
  `Lookup.pending_approvals`: the process tasks the person can act on, as the
  engine answers it — `HumanTask.awaiting_me`, the engine's candidacy read
  (`:awaiting_actor`: open tasks they or a team of theirs are a candidate
  for, claimed tasks they hold, none that excludes them), oldest first, as
  that person. The same read the Approvals surface and the ACP `approvals`
  prompt use.

  The count is `Ash.count/2` over that read, which applies the same
  candidacy filter (ash_bpmn #19), so "how many" agrees with the list
  however long it is. Each row says which decisions its step takes, so the
  model proposes only those (`propose_decision`); deciding stays the
  person's confirm.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Assistant.Lookups.Support
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Platform.LocalTime

  @shown 25

  @impl true
  def run(input, _opts, context) do
    Support.gated(input, context, fn opts ->
      query = Ash.Query.for_read(HumanTask, :awaiting_me, %{}, opts)

      with {:ok, count} <- Ash.count(query, opts),
           {:ok, tasks} <-
             query
             |> Ash.Query.load([
               :subject_label,
               :subject_outline,
               :waiting_since,
               :declared_outcomes
             ])
             |> Ash.Query.limit(@shown)
             |> Ash.read(opts) do
        {:ok,
         %{
           "count" => count,
           "more" => count > length(tasks),
           "approvals" => Enum.map(tasks, &row/1)
         }}
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
      "decisions" => decisions(task.declared_outcomes),
      "waiting_since" => Support.text(task.waiting_since),
      "due" => task.due_at && LocalTime.stamp(task.due_at)
    }
    |> Support.compact()
  end

  # What `propose_decision` can do with it: approve and reject, unless its
  # step declares other outcomes (decided on the task board). A steward
  # decision's approve and reject are its merge and keep-separate
  # (`AshEnterprise.Mdm.StewardTask`).
  defp decisions(outcomes) when outcomes in [nil, []], do: ["approve", "reject"]

  defp decisions(outcomes) do
    cond do
      "confirm" in outcomes -> ["approve (merge)", "reject (keep separate)"]
      "approved" in outcomes or "rejected" in outcomes -> task_decisions(outcomes)
      true -> "decide on the task board (#{Enum.join(outcomes, ", ")})"
    end
  end

  defp task_decisions(outcomes) do
    for {outcome, decision} <- [{"approved", "approve"}, {"rejected", "reject"}],
        outcome in outcomes,
        do: decision
  end
end
