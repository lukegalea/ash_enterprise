defmodule AshEnterprise.Mdm.Changes.EndStewardReview do
  @moduledoc """
  A candidate that is superseded no longer has a question to ask, so its
  `mdm.steward_review` instance is cancelled with it: the open review task
  closes, its clocks are defused, and the run ends `:cancelled`. So does a
  review-banded candidate the machine merged after all, on an admitted yes
  from its certified second opinion (`AshEnterprise.Mdm.SecondOpinion`).

  A steward's confirm or reject completes the review task through
  `StewardVerdict`. Supersession never does: it happens when a merge
  absorbs the candidate's golden (`MergeInto`), when a sweep restages the
  row, or when a sibling candidate of the same row is decided. Without
  this, the run stayed in flight with its task open, on the task board and
  in the flight view, for a pair nobody could decide any more.

  Runs in `after_action`, so it only cancels for a committed supersession,
  and inside the same transaction, so the candidate and its run end
  together. The cancel is engine work (`AshBpmn.cancel_instance/2`), but it
  records who ended the review and why on the instance's cancelled event.
  """

  use Ash.Resource.Change

  require Ash.Query

  @reasons %{
    superseded: "candidate superseded",
    auto_merged: "candidate merged by the machine"
  }

  @impl true
  def change(changeset, _opts, context) do
    with true <- Ash.Changeset.changing_attribute?(changeset, :status),
         {:ok, reason} <- Map.fetch(@reasons, Ash.Changeset.get_attribute(changeset, :status)) do
      Ash.Changeset.after_action(changeset, &cancel_review(&1, &2, context.actor, reason))
    else
      _still_a_question -> changeset
    end
  end

  # The hook is the whole change, so the atomic form is the same changeset:
  # superseding stays an atomic update.
  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp cancel_review(changeset, candidate, actor, reason) do
    AshEnterprise.Bpmn.Instance
    |> Ash.Query.filter(subject_id == ^candidate.id and status == :running)
    |> Ash.read!(tenant: changeset.tenant, authorize?: false)
    |> Enum.each(
      &AshBpmn.cancel_instance!(&1,
        tenant: changeset.tenant,
        actor: actor,
        reason: reason
      )
    )

    {:ok, candidate}
  end
end
