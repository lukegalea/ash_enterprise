defmodule AshEnterprise.Mdm.Changes.StewardVerdict do
  @moduledoc """
  The steward's decision, wired to the System One machinery (MDM-4, ADR 0054):

  1. **Judgment** — the matcher's observation is recorded on the append-only
     judgment ledger (`AshEnterprise.Mdm.MatchObservation`): the declared
     `matches_the_golden` question over this candidate, the score's
     explanation as the state, and the score as the probability of yes.
  2. **HumanVerdict** — the person's answer to that question (`confirm` is
     `true`, `reject` is `false`), on the `:review_task` basis, so it feeds the live
     calibration slot (S1-62) like every other review-task verdict.
  3. **The act.** `confirm` promotes the staged record: survivorship folds
     its mapped values into the golden record, its source identity opens at
     the golden (the XREF the golden's provenance answers through), and the
     staged row is `:merged`. `reject` marks the staged row `:rejected` —
     it stands alone; import completion makes it a golden of its own. A
     people pair (PROD-9, `AshEnterprise.Mdm.People`) is two person rows
     already, so its `confirm` merges the staged row's person into the
     golden instead; this is the one verdict path, so the queue's buttons
     and the steward-decision task (`AshEnterprise.Mdm.StewardTask`) act
     identically.

  Changes run at changeset build, before policies refuse system actors, so
  the verdict work lives in `after_action` — it only ever runs for a
  decision that was authorized and committed.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, &decide/2)
  end

  # Runs inside the action's transaction, only for an authorized decision.
  defp decide(changeset, candidate) do
    tenant = changeset.tenant
    actor = changeset.context[:private][:actor]
    verdict = to_string(changeset.action.name)

    judgment = AshEnterprise.Mdm.MatchObservation.record!(candidate, tenant)
    human = record_human_verdict!(candidate, judgment, verdict, actor, tenant)
    candidate = promote(candidate, act(verdict, candidate, tenant), actor, tenant)

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

    # The process side: this decision completes the review task, as the
    # person, in this transaction, which is what lets the steward-review
    # instance finish. The engine checks they may: a candidate for an open
    # task, the holder of a claimed one. If not, the whole verdict is refused.
    comment = changeset.context[:steward_comment]

    with :ok <- complete_review_task(candidate, verdict, comment, actor, tenant) do
      {:ok, candidate}
    end
  end

  defp complete_review_task(candidate, verdict, comment, actor, tenant) do
    case review_task(candidate, tenant) do
      nil ->
        # No live task: the decision came from the queue before the instance
        # existed, or the tenant runs no steward-review baseline. The verdict
        # rows are the record either way.
        :ok

      task ->
        case AshBpmn.complete_task(task, outcome: verdict, comment: comment, actor: actor) do
          {:ok, _completed} ->
            :ok

          # Not a candidate, or someone else holds it: the task is not theirs
          # to decide, so neither is the candidate while it waits on that task.
          {:error, %ArgumentError{}} ->
            {:error, Ash.Error.Forbidden.exception([])}

          {:error, error} ->
            {:error, error}
        end
    end
  end

  # The engine does not copy the subject onto the task; the join is the
  # instance it belongs to.
  defp review_task(candidate, tenant) do
    with {:ok, %{} = instance} <-
           AshEnterprise.Bpmn.Instance
           |> Ash.Query.filter(subject_id == ^candidate.id and status == ^:running)
           |> Ash.read_one(tenant: tenant, authorize?: false),
         {:ok, %{} = task} <-
           AshEnterprise.Bpmn.HumanTask
           |> Ash.Query.filter(instance_id == ^instance.id and status in [:open, :claimed])
           |> Ash.read_one(tenant: tenant, authorize?: false) do
      task
    else
      _none -> nil
    end
  end

  # -- the observation --------------------------------------------------------

  # -- the person's answer ----------------------------------------------------

  defp record_human_verdict!(_candidate, judgment, verdict, actor, tenant) do
    AshEnterprise.SystemOne.HumanVerdict
    |> Ash.Changeset.for_create(
      :record,
      %{
        judgment_id: judgment.id,
        question_hash: judgment.question_hash,
        model_answer: AshEnterprise.Mdm.MatchObservation.model_answer(judgment),
        human_value: AshEnterprise.Mdm.MatchObservation.human_value(verdict),
        reviewer: to_string(actor.email),
        basis: :review_task
      },
      actor: actor,
      tenant: tenant
    )
    |> Ash.create!()
  end

  # -- the act ----------------------------------------------------------------

  # PROD-9: a confirmed people pair is two person rows already, so the act
  # merges the person, not the staged row (`AshEnterprise.Mdm.People.Pipeline`).
  defp act("confirm", candidate, tenant) do
    staged =
      Ash.get!(AshEnterprise.Mdm.StagedRecord, candidate.staged_record_id,
        tenant: tenant,
        authorize?: false
      )

    if AshEnterprise.Mdm.People.staged?(staged), do: {:people_confirm, staged}, else: "confirm"
  end

  defp act(verdict, _candidate, _tenant), do: verdict

  defp promote(candidate, {:people_confirm, staged}, _actor, tenant) do
    AshEnterprise.Mdm.People.Pipeline.confirm!(candidate, staged, tenant)
    candidate
  end

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

  defp promote(candidate, "reject", actor, tenant) do
    staged =
      Ash.get!(AshEnterprise.Mdm.StagedRecord, candidate.staged_record_id,
        tenant: tenant,
        authorize?: false
      )

    staged
    |> Ash.Changeset.for_update(:update, %{status: :rejected}, tenant: tenant, authorize?: false)
    |> Ash.update!(tenant: tenant, authorize?: false)

    # The reject is the row's verdict — and once no pending candidate needs
    # it, the staged row becomes a golden of its own. Reject is not a dead
    # end: "not that golden" is not "no golden". The deciding steward owns
    # the created record.
    still_pending? =
      AshEnterprise.Mdm.MatchCandidate
      |> Ash.Query.filter(staged_record_id == ^staged.id and status == :pending)
      |> Ash.exists?(tenant: tenant, authorize?: false)

    unless still_pending? do
      # Pre-check, not rescue: this runs inside the reject's transaction,
      # and a unique_email violation would abort it wholesale. The
      # commonest review candidate is "same e-mail, different name" — only
      # one golden per e-mail can exist, so when the e-mail is taken the
      # reject stands (:rejected, golden-less) and the existing person is
      # untouched. "This is not that entity" cannot mean "overwrite the
      # entity it matched".
      mapped = staged.mapped || %{}
      email = mapped["email"]

      email_taken? =
        !is_nil(email) &&
          AshEnterprise.Canonical.Person
          |> Ash.Query.filter(email == ^email)
          |> Ash.exists?(tenant: tenant, authorize?: false)

      unless email_taken? do
        AshEnterprise.Mdm.AutoMerge.create_golden!(staged, actor, tenant)
      end
    end

    candidate
  end

  defp open_identity!(staged, candidate, _actor, tenant) do
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
