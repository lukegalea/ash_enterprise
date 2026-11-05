defmodule AshEnterprise.Quality.Changes.AdmitReplyVerdict do
  @moduledoc """
  A person's verdict on a review-banded agent reply becomes the reply's
  fact, at person grade (S1-96).

  A review-band answer writes no fact (`AshEnterprise.SystemOne.Banding.Step`),
  so the reply reads `unknown` in `AshEnterprise.Quality.Gate`. When a
  person records a verdict on it on the verdicts surface (ADR 0061), this
  change, on `AshEnterprise.SystemOne.HumanVerdict`'s create, admits the
  verdict through `AshJudgments.Facts.Materialiser.materialise_verdict/2`:
  the person's answer is the fact's value, the fact carries the judged
  state's digest, the verdict is its admission, and the grade is
  `:person`. The gate then reads the pair `in` or `out`, at either grade
  floor.

  ## Which verdicts are admitted

  All of these, or none:

    * the basis is `:review_task`, the verdicts surface's: a calibration
      label (`:labelling`, `:audit_sample`) or an override is not a review
      of live work here;
    * the judgment is about an agent reply (`AshEnterprise.Quality.subject_type/0`);
    * its question is one of the `agent_reply_style` questions and its
      `question_hash` is the one declared now: a verdict on a question
      reworded since answers another question, so it stays a label only;
    * the answer is yes or no (stored `"true"` or `"false"`).

  Anything else is left as it was: a label for calibration, no fact.

  A verdict on any other subject type admits nothing yet. A code unit's
  facts carry the unit's digest, not the judged state's, so the verdict's
  digest would not be the fact's; that admission is its own change.

  ## Digest and evidence

  The fact's `subject_state_digest` is the judgment's `state_digest`. For
  a reply that is `AshEnterprise.Quality.digest/1` of the text the model
  judged, so the fact reads `stale` if the reply's text were ever to
  change. The judgment rides along as the decision's evidence, so the
  materialiser asserts the two digests agree before it writes.

  ## Failure and replay

  The write runs in an after-action hook in the verdict's transaction: a
  fact that cannot be written fails the verdict, and the person sees the
  error rather than a recorded verdict the gate cannot see. AshEvents
  strips hooks on replay, so a replayed verdict writes nothing; the
  fact's own `:materialise` event is what `AshEnterprise.SystemOne.FactReplay`
  replays.
  """

  use Ash.Resource.Change

  require Logger

  alias AshEnterprise.Quality
  alias AshEnterprise.Quality.Questions
  alias AshEnterprise.SystemOne.Judgment
  alias AshJudgments.Facts.Materialiser

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, verdict ->
      if verdict.basis == :review_task do
        admit(verdict, changeset)
      else
        {:ok, verdict}
      end
    end)
  end

  defp admit(verdict, changeset) do
    # The verdict cites the judgment it answers; reading it is provenance
    # for the person's own answer, as in CalibrationSampleWriter.
    judgment =
      Ash.get!(Judgment, verdict.judgment_id, authorize?: false, tenant: changeset.tenant)

    case decision(verdict, judgment) do
      {:ok, decision} -> materialise(decision, verdict)
      :skip -> {:ok, verdict}
    end
  end

  defp decision(verdict, judgment) do
    with true <- judgment.subject_type == Quality.subject_type(),
         {:ok, name} <- Questions.name_for(judgment.question_id),
         :ok <- current_wording(name, judgment),
         {:ok, value} <- boolean(verdict.human_value) do
      question = Questions.fetch!(name)

      {:ok,
       %{
         judgment_id: judgment.id,
         subject: %{"type" => judgment.subject_type, "id" => judgment.subject_id},
         predicate: judgment.question_id,
         value: value,
         holds: value == question.holds_value,
         subject_state_digest: judgment.state_digest,
         admission_id: verdict.id,
         evidence_observation: judgment
       }}
    else
      _ -> :skip
    end
  end

  defp current_wording(name, judgment) do
    if Questions.declared(name).question_hash == judgment.question_hash do
      :ok
    else
      Logger.info(
        "verdict on judgment #{judgment.id} admitted no fact: " <>
          "#{name} was reworded since it was judged"
      )

      :skip
    end
  end

  defp materialise(decision, verdict) do
    case Materialiser.materialise_verdict(decision) do
      {:ok, _outcome} -> {:ok, verdict}
      {:error, error} -> {:error, error}
    end
  end

  defp boolean("true"), do: {:ok, true}
  defp boolean("false"), do: {:ok, false}
  defp boolean(_value), do: :skip
end
