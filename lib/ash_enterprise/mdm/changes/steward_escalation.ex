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

  @question_id "judgment:v0:AshEnterprise.Mdm.MatchCandidate#matches_the_golden"
  @family "mdm_matches"

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, &escalate/2)
  end

  defp escalate(changeset, candidate) do
    tenant = changeset.tenant
    actor = changeset.context[:private][:actor]
    verdict = "unsure"

    judgment = record_judgment!(candidate, tenant)
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

  defp record_judgment!(candidate, tenant) do
    state = %{
      "explanation" => candidate.explanation,
      "score" => Decimal.to_string(candidate.score)
    }

    AshEnterprise.SystemOne.Judgment
    |> Ash.Changeset.for_create(
      :record,
      [
        id: Ash.UUID.generate(),
        question_id: @question_id,
        question_hash: AshJudgments.Registry.Canonical.digest(@question_id),
        question_version: 1,
        family: @family,
        subject_type: "match_candidate",
        subject_id: candidate.id,
        state_digest:
          AshJudgments.Registry.Canonical.digest(AshJudgments.Registry.Canonical.encode(state)),
        answer_kind: :choice,
        value: "match",
        probabilities: %{},
        confidence: Decimal.to_string(candidate.score),
        model_spec_requested: "ash_mdm:rules-as-data",
        model_version: "mdm-match-1",
        model_digest:
          AshJudgments.Registry.Canonical.digest(AshJudgments.Registry.Canonical.encode(state)),
        runtime_version: "0.9.0",
        profile: "ash_mdm",
        latency_us: 0,
        mode: :live,
        correlation_id: nil,
        valid_until: nil
      ],
      actor: AshEnterprise.Platform.SystemActor.process(),
      tenant: tenant
    )
    |> Ash.create!()
  end

  defp record_human_verdict!(candidate, judgment, verdict, actor, tenant) do
    AshEnterprise.SystemOne.HumanVerdict
    |> Ash.Changeset.for_create(
      :record,
      %{
        judgment_id: judgment.id,
        question_hash: judgment.question_hash,
        model_answer: %{"kind" => "exact", "value" => "match", "distribution" => %{}},
        human_value: verdict,
        reason:
          "Steward escalated match candidate #{candidate.id}: the verdict stays open for a senior steward.",
        reviewer: to_string(actor.email),
        basis: :review_task
      },
      actor: actor,
      tenant: tenant
    )
    |> Ash.create!()
  end
end
