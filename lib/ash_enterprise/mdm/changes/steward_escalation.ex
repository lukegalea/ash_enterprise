defmodule AshEnterprise.Mdm.Changes.StewardEscalation do
  @moduledoc """
  The steward cannot decide (MDM-8's fourth act, "unsure — escalate"): the
  verdict is recorded, the candidate stays pending for a senior steward.

  Mirrors `StewardVerdict`'s ledger wiring — the model's observation on the
  judgment ledger, the person's answer on the HumanVerdict ledger with the
  `:review_task` basis — but with the answer `"unsure"`:

  - `status` is NOT changed (the candidate stays `:pending`, in the queue);
  - no promotion runs (nothing merges, nothing stands alone);
  - the BPMN review task is NOT completed (escalation keeps the task open —
    a senior steward resolves it, and their decision completes it through
    the same confirm/reject seam).

  Runs in `after_action` for the same reason StewardVerdict's work does:
  it only ever runs for an authorized, committed escalation.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, &escalate/2)
  end

  defp escalate(changeset, candidate) do
    tenant = changeset.tenant
    actor = changeset.context[:private][:actor]
    verdict = "unsure"

    judgment = AshEnterprise.Mdm.MatchObservation.record!(candidate, tenant)
    human = record_human_verdict!(candidate, judgment, verdict, actor, tenant)

    ref = %{"verdict" => verdict, "verdict_id" => human.id, "judgment_id" => judgment.id}

    candidate
    |> Ash.Changeset.for_update(:record_verdict_ref, %{human_verdict_ref: ref},
      tenant: tenant,
      authorize?: false
    )
    |> Ash.update!(tenant: tenant, authorize?: false)

    {:ok, candidate}
  end

  defp record_human_verdict!(candidate, judgment, verdict, actor, tenant) do
    AshEnterprise.SystemOne.HumanVerdict
    |> Ash.Changeset.for_create(
      :record,
      %{
        judgment_id: judgment.id,
        question_hash: judgment.question_hash,
        model_answer: AshEnterprise.Mdm.MatchObservation.model_answer(judgment),
        human_value: verdict,
        reason:
          "Steward escalated match candidate #{candidate.id}: the verdict stays open for a senior steward.",
        reviewer: to_string(actor.email),
        # An escalation is not an answer to the question, so it does not
        # feed calibration: `:override` is the basis the sample writer skips.
        basis: :override
      },
      actor: actor,
      tenant: tenant
    )
    |> Ash.create!()
  end
end
