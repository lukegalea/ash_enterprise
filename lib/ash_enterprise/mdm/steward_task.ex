defmodule AshEnterprise.Mdm.StewardTask do
  @moduledoc """
  A steward-decision task (the `mdm.steward_review` process's user task) and
  the match candidate it decides.

  The decision is the candidate's own person-gated update — `:confirm`,
  `:reject` or `:escalate` on `AshEnterprise.Mdm.MatchCandidate` — never the
  task's completion on its own: completing the task with "confirm" while the
  candidate stayed pending would end the process with nothing merged. So
  wherever the person decides — the task board's Complete, Approvals'
  Approve / Reject, or the steward queue — the verdict is recorded on the
  candidate **as the person**, and the verdict's `after_action`
  (`AshEnterprise.Mdm.Changes.StewardVerdict`) completes the task through the
  engine in the same transaction, as the person. The engine checks they may
  complete it (a candidate for an open task, the holder of a claimed one); if
  not, the verdict is refused and nothing is written.

  | Outcome | Verdict |
  |---|---|
  | `confirm` (board), `approved` (Approvals) | `:confirm` — the staged record merges into the golden |
  | `reject` (board), `rejected` (Approvals) | `:reject` — the staged record stands alone |
  | `escalate` (board) | `:escalate` — recorded as unsure; the candidate stays pending and the task stays with the person, who can delegate it to a senior steward |

  Escalating completes nothing, so it is the one verdict this module checks
  the person may act on the task for itself (`AshBpmn.Candidacy`).
  """

  alias AshBpmn.{Candidacy, Scope}
  alias AshEnterprise.Mdm.MatchCandidate

  @subject_type to_string(MatchCandidate)

  @doc """
  `{:ok, candidate_id}` when `task` decides a match candidate (its instance's
  subject is one), else `:none`. The instance is read with the engine's
  authority: which process a task belongs to is a fact about the task.
  """
  @spec candidate_id(struct()) :: {:ok, Ash.UUID.t()} | :none
  def candidate_id(%{instance_id: nil}), do: :none

  def candidate_id(task) do
    scope = Scope.from_record(task)

    case Ash.get(AshEnterprise.Bpmn.Instance, task.instance_id, Scope.engine(scope)) do
      {:ok, %{subject_type: @subject_type, subject_id: id}} when not is_nil(id) -> {:ok, id}
      _other -> :none
    end
  end

  @doc """
  Records the verdict `outcome` stands for on the candidate, as the actor in
  `opts`, with `comment` carried onto the task it completes.
  """
  @spec decide(struct(), Ash.UUID.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def decide(task, candidate_id, outcome, comment, opts) do
    with {:ok, verdict} <- verdict(outcome),
         :ok <- may_escalate(verdict, task, opts[:actor]),
         {:ok, candidate} <- Ash.get(MatchCandidate, candidate_id, opts),
         {:ok, _decided} <-
           candidate
           |> Ash.Changeset.for_update(verdict, %{}, opts)
           |> Ash.Changeset.set_context(%{steward_comment: comment})
           |> Ash.update(opts) do
      {:ok, message(verdict)}
    end
  end

  defp verdict(outcome) when outcome in ["confirm", "approved"], do: {:ok, :confirm}
  defp verdict(outcome) when outcome in ["reject", "rejected"], do: {:ok, :reject}
  defp verdict("escalate"), do: {:ok, :escalate}
  defp verdict(_other), do: {:error, "a steward decision is confirm, reject or escalate"}

  defp may_escalate(:escalate, task, actor) do
    scope = Scope.from_record(task, actor: actor)
    principals = Candidacy.for_actor(actor, scope)

    allowed? =
      case task.status do
        :claimed -> Candidacy.holds?(task, principals)
        :open -> Candidacy.candidate?(resources(), task, principals, scope)
        _decided -> false
      end

    if allowed?, do: :ok, else: {:error, %ArgumentError{message: "not this task's to escalate"}}
  end

  defp may_escalate(_verdict, _task, _actor), do: :ok

  defp resources do
    {:ok, resources} = AshBpmn.Resources.for_domain(AshEnterprise.Bpmn)
    resources
  end

  defp message(:confirm), do: "Match confirmed: the staged record merged into the golden record."
  defp message(:reject), do: "Match rejected: the staged record stays a record of its own."

  defp message(:escalate),
    do:
      "Marked unsure: the candidate stays open and the task stays with you — " <>
        "delegate it to a senior steward."
end
