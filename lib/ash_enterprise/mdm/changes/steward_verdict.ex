defmodule AshEnterprise.Mdm.Changes.StewardVerdict do
  @moduledoc """
  The steward's decision, wired to the System One machinery (MDM-4, ADR 0050):

  1. **Judgment** — the model's observation is recorded on the append-only
     judgment ledger: the match question over this candidate, the score's
     explanation as the state, and `match` as the model's answer (the
     candidate exists because the matcher proposed it).
  2. **HumanVerdict** — the person's correction or confirmation of that
     observation, on the `:review_task` basis, so it feeds the live
     calibration slot (S1-62) like every other review-task verdict.
  3. **The act.** `confirm` promotes the staged record: survivorship folds
     its mapped values into the golden record, its source identity opens at
     the golden (the XREF the golden's provenance answers through), and the
     staged row is `:merged`. `reject` marks the staged row `:rejected` —
     it stands alone; import completion makes it a golden of its own.

  Changes run at changeset build, before policies refuse system actors, so
  the verdict work lives in `after_action` — it only ever runs for a
  decision that was authorized and committed.
  """

  use Ash.Resource.Change

  require Ash.Query

  @question_id "judgment:v0:AshEnterprise.Mdm.MatchCandidate#matches_the_golden"
  @family "mdm_matches"

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, &decide/2)
  end

  # Runs inside the action's transaction, only for an authorized decision.
  defp decide(changeset, candidate) do
    tenant = changeset.tenant
    actor = changeset.context[:private][:actor]
    verdict = to_string(changeset.action.name)

    judgment = record_judgment!(candidate, tenant)
    human = record_human_verdict!(candidate, judgment, verdict, actor, tenant)
    candidate = promote(candidate, verdict, actor, tenant)

    ref = %{"verdict" => verdict, "verdict_id" => human.id, "judgment_id" => judgment.id}

    # The decision's own write has committed; the ref points at the verdict
    # rows that only exist now, so it rides a narrow follow-up write.
    candidate =
      candidate
      |> Ash.Changeset.for_update(:record_verdict_ref, %{human_verdict_ref: ref},
        tenant: tenant,
        authorize?: false
      )
      |> Ash.update!(tenant: tenant, authorize?: false)

    # The process side: this decision completes the review task, which is
    # what lets the steward-review instance finish.
    complete_review_task!(candidate, verdict, actor, tenant)

    {:ok, candidate}
  end

  defp complete_review_task!(candidate, verdict, actor, tenant) do
    # The engine does not copy the subject onto the task; the join is the
    # instance it belongs to.
    open_task =
      AshEnterprise.Bpmn.Instance
      |> Ash.Query.filter(subject_id == ^candidate.id and status == ^:running)
      |> Ash.read_one(tenant: tenant, authorize?: false)
      |> case do
        {:ok, instance} when not is_nil(instance) ->
          AshEnterprise.Bpmn.HumanTask
          |> Ash.Query.filter(instance_id == ^instance.id and status == :open)
          |> Ash.read_one(tenant: tenant, authorize?: false)
          |> case do
            {:ok, task} -> task
            _ -> nil
          end

        _ ->
          nil
      end

    open_task
    |> case do
      task when not is_nil(task) ->
        AshBpmn.complete_task!(task, outcome: verdict, actor: actor)

      _ ->
        # No open task: the decision came from the queue before the instance
        # existed, or the tenant runs no steward-review baseline. The verdict
        # rows are the record either way.
        :ok
    end
  end

  # -- the observation --------------------------------------------------------

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

  # -- the person's answer ----------------------------------------------------

  defp record_human_verdict!(candidate, judgment, verdict, actor, tenant) do
    AshEnterprise.SystemOne.HumanVerdict
    |> Ash.Changeset.for_create(
      :record,
      %{
        judgment_id: judgment.id,
        question_hash: judgment.question_hash,
        model_answer: %{"kind" => "exact", "value" => "match", "distribution" => %{}},
        human_value: if(verdict == "confirm", do: "match", else: "no_match"),
        reviewer: to_string(actor.email),
        basis: :review_task
      },
      actor: actor,
      tenant: tenant
    )
    |> Ash.create!()
  end

  # -- the act ----------------------------------------------------------------

  defp promote(candidate, "confirm", actor, tenant) do
    staged =
      Ash.get!(AshEnterprise.Mdm.StagedRecord, candidate.staged_record_id,
        tenant: tenant,
        authorize?: false
      )

    golden =
      Ash.get!(AshEnterprise.Canonical.Person, candidate.golden_id,
        tenant: tenant,
        authorize?: false
      )

    # The same survivorship fold and identity opening the admit band runs —
    # the person's decision just authorises it here, with the steward
    # asserted as the identity's source (the machine path asserts :mapping).
    AshEnterprise.Mdm.AutoMerge.fold!(staged, golden, tenant)
    open_identity!(staged, candidate, actor, tenant)

    staged
    |> Ash.Changeset.for_update(:update, %{status: :merged}, tenant: tenant, authorize?: false)
    |> Ash.update!(tenant: tenant, authorize?: false)

    candidate
  end

  defp promote(candidate, "reject", _actor, tenant) do
    staged =
      Ash.get!(AshEnterprise.Mdm.StagedRecord, candidate.staged_record_id,
        tenant: tenant,
        authorize?: false
      )

    staged
    |> Ash.Changeset.for_update(:update, %{status: :rejected}, tenant: tenant, authorize?: false)
    |> Ash.update!(tenant: tenant, authorize?: false)

    candidate
  end

  defp open_identity!(staged, candidate, actor, tenant) do
    source_record =
      Ash.get!(AshEnterprise.Mdm.SourceRecord, staged.source_record_id, authorize?: false)

    AshEnterprise.Mdm.SourceIdentity
    |> Ash.Changeset.for_create(
      :open,
      %{
        source: to_string(source_record.source),
        stream: to_string(source_record.stream),
        external_id: source_record.external_id,
        golden_resource: candidate.golden_resource,
        golden_id: candidate.golden_id,
        asserted_by: :steward,
        confidence: candidate.score
      },
      tenant: tenant,
      authorize?: false
    )
    |> Ash.create!(tenant: tenant, authorize?: false)

    :ok
  end
end
