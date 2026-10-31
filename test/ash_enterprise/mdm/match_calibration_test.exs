defmodule AshEnterprise.Mdm.MatchCalibrationTest do
  @moduledoc """
  MDM-S1-1: the match question is declared and locked, and the steward's
  verdicts on it earn `mdm:match_bands`.

  Confirms and rejects land as calibration samples for `mdm_matches`; a run
  over the labelled pairs proposes a table once n reaches the family's
  `min_n`; certifying and publishing it under the key the matcher already
  bands through makes `AshEnterprise.Mdm.Banding.band/3` admit above the
  earned threshold.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Mdm.TestSupport

  alias AshEnterprise.Decisions.Definition
  alias AshEnterprise.Mdm.Banding
  alias AshEnterprise.Mdm.MatchObservation
  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.SystemOne.Banding.Resolver
  alias AshEnterprise.SystemOne.BandTableCertification
  alias AshEnterprise.SystemOne.BandTablePublication
  alias AshEnterprise.SystemOne.Calibration
  alias AshEnterprise.SystemOne.CalibrationInput
  alias AshEnterprise.SystemOne.CalibrationSample
  alias AshEnterprise.SystemOne.HumanVerdict
  alias AshEnterprise.SystemOne.Judgment
  alias AshJudgments.Calibration.ProposalDmn

  require Ash.Query

  @family "mdm_matches"
  @key "mdm:match_bands"

  setup do
    AshEnterprise.Process.Resolver.forget_platform_tenant()
    on_exit(&AshEnterprise.Process.Resolver.forget_platform_tenant/0)

    platform = Seeder.seed_platform_organization()
    Banding.publish_seed_bands!(platform.id)

    n = System.unique_integer([:positive])

    %{organization: organization, user: admin} =
      Seeder.seed_tenant(name: "Calib #{n}", unique_name: "calib-#{n}")

    # The family's policy data, shrunk for tests (law 5: config, not code).
    Application.put_env(:ash_judgments, :families, %{
      @family => %{min_n: 4, min_n_per_class: nil, alpha: 0.2, max_age_days: 90}
    })

    on_exit(fn -> Application.delete_env(:ash_judgments, :families) end)

    %{org: organization.id, admin: admin, platform: platform.id}
  end

  test "the question is declared, locked, and routed to the band table MDM already uses" do
    question = MatchObservation.question()

    assert question.question_id ==
             "judgment:v0:AshEnterprise.Mdm.MatchCandidate#judgments/matches_the_golden"

    assert question.type == AshAi.Evaluate.Noul
    assert to_string(question.family) == @family
    assert Resolver.band_table_key(@family) == @key

    lock = "priv/judgments/lock.json" |> File.read!() |> Jason.decode!()
    assert lock[question.question_id]["hash"] == question.question_hash
  end

  test "steward verdicts earn mdm:match_bands", ctx do
    %{org: org, admin: admin, platform: platform} = ctx

    # Before: the seed table bands 0.8 as review.
    assert {:ok, :review} = Banding.band(Decimal.new("0.80"), org)

    decided =
      for {score, verdict, n} <- [
            {"0.97", :confirm, 1},
            {"0.93", :confirm, 2},
            {"0.45", :reject, 3},
            {"0.30", :reject, 4}
          ] do
        {candidate, _staged, _golden} =
          staged_candidate!(
            org,
            admin,
            "Cal #{n}",
            "cal#{n}-#{System.unique_integer([:positive])}@x.io",
            score: score
          )

        decided =
          candidate
          |> Ash.Changeset.for_update(verdict, %{}, tenant: org, actor: admin)
          |> Ash.update!(tenant: org, actor: admin)

        {decided, score, verdict}
      end

    # The observation is a noul with the score as the yes probability.
    for {candidate, score, verdict} <- decided do
      judgment =
        Ash.get!(Judgment, candidate.human_verdict_ref["judgment_id"],
          tenant: org,
          authorize?: false
        )

      assert judgment.answer_kind == :noul
      assert judgment.question_hash == MatchObservation.question().question_hash
      assert Decimal.equal?(Decimal.new(judgment.probabilities["true"]), Decimal.new(score))

      assert Decimal.equal?(
               Decimal.new(judgment.probabilities["false"]),
               Decimal.sub(1, Decimal.new(score))
             )

      human =
        Ash.get!(HumanVerdict, candidate.human_verdict_ref["verdict_id"],
          tenant: org,
          authorize?: false
        )

      assert human.human_value == if(verdict == :confirm, do: "true", else: "false")
    end

    # Each verdict landed as a calibration sample for the family.
    samples =
      CalibrationSample
      |> Ash.Query.filter(family == ^@family)
      |> Ash.read!(tenant: org, authorize?: false)

    assert length(samples) == 4

    assert samples |> Enum.map(& &1.question_hash) |> Enum.uniq() == [
             MatchObservation.question().question_hash
           ]

    # An escalation is not an answer: it adds no sample.
    {pending, _staged, _golden} =
      staged_candidate!(org, admin, "Esc", "esc-#{System.unique_integer([:positive])}@x.io")

    pending
    |> Ash.Changeset.for_update(:escalate, %{}, tenant: org, actor: admin)
    |> Ash.update!(tenant: org, actor: admin)

    assert CalibrationSample
           |> Ash.Query.filter(family == ^@family)
           |> Ash.read!(tenant: org, authorize?: false)
           |> length() == 4

    # The eval set is the labelled pairs: the observation's yes probability
    # and the steward's answer.
    pairs =
      for {candidate, _score, _verdict} <- decided do
        judgment =
          Ash.get!(Judgment, candidate.human_verdict_ref["judgment_id"],
            tenant: org,
            authorize?: false
          )

        human =
          Ash.get!(HumanVerdict, candidate.human_verdict_ref["verdict_id"],
            tenant: org,
            authorize?: false
          )

        %{
          "p" => judgment.probabilities["true"] |> Decimal.new() |> Decimal.to_float(),
          "gold" => human.human_value == "true",
          "observation_id" => judgment.id
        }
      end

    judgments =
      for {candidate, _, _} <- decided,
          do:
            Ash.get!(Judgment, candidate.human_verdict_ref["judgment_id"],
              tenant: org,
              authorize?: false
            )

    [first | _] = judgments

    doc = %{
      "family" => @family,
      "answer_kind" => "noul",
      "question_hashes" => [MatchObservation.question().question_hash],
      "model_version" => first.model_version,
      "model_digest" => first.model_digest,
      "runtime_version" => first.runtime_version,
      "region" => first.region,
      "tenant" => org,
      "created_by" => "mdm-s1-1-test",
      "observations_digest" =>
        AshJudgments.Registry.Canonical.digest(Enum.map(judgments, & &1.id)),
      "pairs" => pairs
    }

    input = CalibrationInput.input(doc, Jason.encode!(doc))
    attrs = CalibrationInput.run_attrs(@family, input)

    # Below min_n nothing is proposed.
    {:ok, small, {:refused, _}} =
      Calibration.record_run(%{attrs | n: 3}, actor: SystemActor.process(), tenant: org)

    assert small.result == :no_table

    {:ok, run, {:proposed, proposal}} =
      Calibration.record_run(attrs, actor: SystemActor.process(), tenant: org)

    assert run.result == :proposed_table
    assert proposal.definition_key == @key

    {:ok, xml} = ProposalDmn.render(proposal, score_input: "score")

    draft =
      Definition.create!(%{key: @key, name: "MDM match bands (earned)", xml: xml},
        authorize?: false,
        tenant: platform
      )

    certification =
      BandTableCertification
      |> Ash.Changeset.for_create(
        :record,
        %{
          definition_key: @key,
          definition_version: to_string(draft.version),
          content_hash: draft.content_hash,
          family: @family,
          calibration_run_id: run.id,
          certified_by: to_string(admin.email)
        },
        actor: admin,
        tenant: org
      )
      |> Ash.create!()

    assert {:ok, %{status: :published}} =
             BandTablePublication.publish(
               %{
                 family: @family,
                 model_digest: run.model_digest,
                 runtime_version: run.runtime_version,
                 region: run.region
               },
               certification,
               run,
               actor: SystemActor.process(),
               tenant: platform
             )

    threshold = run.conformal_thresholds |> Map.values() |> hd() |> Map.fetch!("threshold")
    {threshold, ""} = Float.parse(to_string(threshold))

    # After: a score above the earned threshold is admitted, one below is not.
    assert threshold < 0.97
    assert {:ok, :admit} = Banding.band(Decimal.new("0.97"), org)
    assert {:ok, :review} = Banding.band(Decimal.new("0.30"), org)
  end
end
