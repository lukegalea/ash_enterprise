defmodule AshEnterprise.Assistant.Lookups.Approvals do
  @moduledoc """
  `Lookup.Approval.pending_approvals`: the process tasks the person can act on, as the
  engine answers it — `HumanTask.awaiting_me`, the engine's candidacy read
  (`:awaiting_actor`: open tasks they or a team of theirs are a candidate
  for, claimed tasks they hold, none that excludes them), oldest first, as
  that person. The same read the Approvals surface and the ACP `approvals`
  prompt use.

  At most #{25}, the oldest first. Each row says which decisions its step takes, so the
  model proposes only those (`propose_decision`); deciding stays the
  person's confirm.
  """

  use Ash.Resource.ManualRead

  alias AshEnterprise.Assistant.Lookup
  alias AshEnterprise.Assistant.Lookups.Support
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Platform.LocalTime

  @shown 25

  @impl true
  def read(query, _data_layer_query, _opts, context) do
    Support.gated(query, context, fn opts ->
      HumanTask
      |> Ash.Query.for_read(:awaiting_me, %{}, opts)
      |> Ash.Query.load([:subject_label, :subject_outline, :waiting_since, :declared_outcomes])
      |> Ash.Query.limit(@shown)
      |> Ash.read(opts)
      |> case do
        {:ok, tasks} -> {:ok, Enum.map(tasks, &row/1)}
        error -> error
      end
    end)
  end

  defp row(task) do
    Support.row(Lookup.Approval, %{
      ref: Support.ref(HumanTask, task),
      task: task.name,
      about: Support.text(task.subject_label),
      outline: Support.text(task.subject_outline),
      status: task.status,
      decisions: decisions(task.declared_outcomes),
      waiting_since: Support.text(task.waiting_since),
      due: task.due_at && LocalTime.stamp(task.due_at)
    })
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
      true -> ["decide on the task board (#{Enum.join(outcomes, ", ")})"]
    end
  end

  defp task_decisions(outcomes) do
    for {outcome, decision} <- [{"approved", "approve"}, {"rejected", "reject"}],
        outcome in outcomes,
        do: decision
  end
end
