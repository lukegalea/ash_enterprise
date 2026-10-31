defmodule AshEnterprise.Mdm.MatchObservation do
  @moduledoc """
  The matcher's observation of a candidate pair, recorded on the judgment
  ledger for a steward to answer (ADR 0054).

  The question is `MatchCandidate`'s declared `matches_the_golden`: a yes/no
  `Noul` whose id and hash are locked in `priv/judgments/lock.json`. Nothing
  asks a model. The matcher's rules-as-data score is the observation, and it
  is recorded as the probability of yes (`true` = score, `false` = 1 -
  score), the shape the calibration path reads, so a conformal threshold on
  the score can be earned for `mdm:match_bands`.

  A steward's `confirm` is the answer `"true"` and `reject` is `"false"`
  (`human_value/1`).
  """

  alias AshEnterprise.SystemOne.Judgment
  alias AshJudgments.Registry.Canonical

  @question :matches_the_golden
  @family "mdm_matches"

  @doc "The declared question."
  def question,
    do: AshJudgments.Registry.Info.question(AshEnterprise.Mdm.MatchCandidate, @question)

  @doc "The family the steward verdicts calibrate."
  def family, do: @family

  @doc "A steward's verdict in the question's answer space."
  def human_value("confirm"), do: "true"
  def human_value("reject"), do: "false"

  @doc "The model-answer snapshot a verdict cites."
  def model_answer(judgment) do
    %{"kind" => "noul", "value" => nil, "distribution" => judgment.probabilities}
  end

  @doc "Records the matcher's observation of `candidate` as the system actor."
  def record!(candidate, tenant) do
    question = question()

    state = %{
      "explanation" => candidate.explanation,
      "score" => Decimal.to_string(candidate.score)
    }

    digest = Canonical.digest(Canonical.encode(state))

    Judgment
    |> Ash.Changeset.for_create(
      :record,
      [
        id: Ash.UUID.generate(),
        question_id: question.question_id,
        question_hash: question.question_hash,
        question_version: question.version,
        family: @family,
        subject_type: "match_candidate",
        subject_id: candidate.id,
        state_digest: digest,
        answer_kind: :noul,
        value: nil,
        probabilities: probabilities(candidate.score),
        confidence: nil,
        model_spec_requested: "ash_mdm:rules-as-data",
        model_version: "mdm-match-1",
        model_digest: digest,
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

  defp probabilities(score) do
    score = Decimal.new(to_string(score))

    %{
      "true" => Decimal.to_string(score),
      "false" => score |> then(&Decimal.sub(1, &1)) |> Decimal.to_string()
    }
  end
end
