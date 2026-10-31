defmodule AshEnterprise.Standards.BandTableTest do
  @moduledoc """
  AST-138: a standards family's band table as the calibration loop earns
  it. The run's proposal is rendered by
  `AshJudgments.Calibration.ProposalDmn` over the family's score inputs,
  certified, published, and then bands the family's answers through the
  host banding step with the default resolver: no stub table.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.SystemOne.Support

  alias AshEnterprise.Decisions.Definition
  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Standards
  alias AshEnterprise.Standards.Questions
  alias AshEnterprise.SystemOne.Banding.Resolver
  alias AshEnterprise.SystemOne.Banding.Step
  alias AshEnterprise.SystemOne.BandTableCertification
  alias AshEnterprise.SystemOne.BandTablePublication
  alias AshEnterprise.SystemOne.Calibration
  alias AshJudgments.Calibration.ProposalDmn

  @family "house_style"

  setup do
    Correlation.start_new()

    # The family's policy data, shrunk for tests (law 5: config, not code).
    put_family!(@family, %{min_n: 2, min_n_per_class: nil, alpha: 0.016, max_age_days: 90})

    %{org: Ash.UUID.generate(), person: person()}
  end

  test "a family's score inputs are its yes/no questions' p_true" do
    assert Questions.score_inputs(:commenting) == ["comments_are_durable_facts_only__p_true"]

    inputs = Questions.score_inputs(@family)
    assert length(inputs) == 8
    assert "hs1_lead_with_outcome_or_ask__p_true" in inputs
    refute Enum.any?(inputs, &String.starts_with?(&1, "hs9_"))
    assert Questions.score_inputs(:query_strategy) == []
  end

  test "the rendered table bands every question of the family, one answer at a time", ctx do
    platform = AshEnterprise.Platform.Seeder.seed_platform_organization()
    AshEnterprise.Process.Resolver.forget_platform_tenant()
    key = Resolver.band_table_key(@family)

    {:ok, run, {:proposed, proposal}} =
      Calibration.record_run(run_attrs(),
        actor: SystemActor.process(),
        tenant: ctx.org
      )

    {:ok, xml} = ProposalDmn.render(proposal, score_input: Questions.score_inputs(@family))

    draft =
      Definition.create!(%{key: key, name: key, xml: xml}, authorize?: false, tenant: platform.id)

    certification =
      BandTableCertification
      |> Ash.Changeset.for_create(
        :record,
        %{
          definition_key: key,
          definition_version: to_string(draft.version),
          content_hash: draft.content_hash,
          family: @family,
          calibration_run_id: run.id,
          certified_by: to_string(ctx.person.email)
        },
        actor: ctx.person,
        tenant: ctx.org
      )
      |> Ash.create!()

    assert {:ok, %{status: :published}} =
             BandTablePublication.publish(
               %{
                 family: @family,
                 model_digest: run.model_digest,
                 runtime_version: run.runtime_version,
                 region: "ca"
               },
               certification,
               run,
               actor: SystemActor.process(),
               tenant: platform.id
             )

    # Two bandings in one tenant: the resolver reads back this call's
    # recorded evaluation, not the first one's.
    assert {:ok, %{band: :admit, banding: admitted}} =
             band(ctx, :hs1_lead_with_outcome_or_ask, 0.97)

    assert admitted.matched_rule_ids == ["rule_admit"]
    # The admitted yes is the fact: `true`, which holds for a yes/no
    # standard (its holds_value).
    assert admitted.fact_value == true

    assert [fact] = AshEnterprise.SystemOne.Fact |> Ash.read!(tenant: ctx.org, authorize?: false)
    assert fact.value == true
    assert fact.holds == true

    assert {:ok, %{band: :review, banding: reviewed}} =
             band(ctx, :hs5_promise_only_agreed_to, 0.4)

    assert reviewed.matched_rule_ids == ["rule_review"]
    assert reviewed.fact_value == nil
    refute reviewed.decision_evaluation_id == admitted.decision_evaluation_id
  end

  test "an earned three-range table admits a confident yes as true and a confident no as false",
       ctx do
    publish_earned!(ctx, %{"threshold" => "0.9", "threshold_low" => "0.12"})

    # The family's configured low band admits the confident no.
    assert AshJudgments.Calibration.FamilyConfig.low_band(@family) == :admit_no

    assert {:ok, %{band: :admit, banding: yes}} =
             band(ctx, :hs1_lead_with_outcome_or_ask, 0.97, "yes")

    assert yes.matched_rule_ids == ["rule_admit"]
    assert yes.fact_value == true

    assert {:ok, %{band: :review, banding: unsure}} =
             band(ctx, :hs1_lead_with_outcome_or_ask, 0.5, "unsure")

    assert unsure.matched_rule_ids == ["rule_review"]
    assert unsure.fact_value == nil

    assert {:ok, %{band: :admit, banding: no}} =
             band(ctx, :hs1_lead_with_outcome_or_ask, 0.05, "no")

    assert no.matched_rule_ids == ["rule_admit_no"]
    assert no.reason_code == "conformal_low_threshold_met"
    # A boolean, the same JSON kind a yes is stored as: not the string "false".
    assert no.fact_value == false

    # Both admissions are facts (one unit each); the review wrote none. The yes holds for a
    # yes/no standard (holds_value true) and the no does not.
    facts =
      AshEnterprise.SystemOne.Fact
      |> Ash.read!(tenant: ctx.org, authorize?: false)
      |> Enum.map(&{&1.admission_id, &1.value, &1.holds})
      |> Enum.sort()

    assert facts == Enum.sort([{yes.id, true, true}, {no.id, false, false}])
  end

  test "an :omit low band drops a confident no: a banding, and no fact", ctx do
    put_family!(@family, %{low_band: :omit})
    publish_earned!(ctx, %{"threshold" => "0.9", "threshold_low" => "0.12"})

    assert {:ok, %{band: :omit, banding: dropped}} =
             band(ctx, :hs1_lead_with_outcome_or_ask, 0.05)

    assert dropped.matched_rule_ids == ["rule_omit"]
    assert dropped.fact_value == nil
    assert [] = AshEnterprise.SystemOne.Fact |> Ash.read!(tenant: ctx.org, authorize?: false)

    # This table has no `fact_value` output, so the admitted yes takes its
    # value from the answer: a yes/no answer admitted on p_true is `true`.
    assert {:ok, %{band: :admit, banding: yes}} =
             band(ctx, :hs1_lead_with_outcome_or_ask, 0.97, "yes")

    assert yes.matched_rule_ids == ["rule_admit"]
    assert yes.fact_value == true

    assert [fact] = AshEnterprise.SystemOne.Fact |> Ash.read!(tenant: ctx.org, authorize?: false)
    assert {fact.admission_id, fact.value, fact.holds} == {yes.id, true, true}
  end

  # Records, renders (with the family's low band, as the certify act does),
  # certifies and publishes an earned table for the family.
  defp publish_earned!(ctx, thresholds) do
    platform = AshEnterprise.Platform.Seeder.seed_platform_organization()
    AshEnterprise.Process.Resolver.forget_platform_tenant()
    key = Resolver.band_table_key(@family)

    {:ok, run, {:proposed, proposal}} =
      Calibration.record_run(%{run_attrs() | conformal_thresholds: %{"0.016" => thresholds}},
        actor: SystemActor.process(),
        tenant: ctx.org
      )

    {:ok, xml} =
      ProposalDmn.render(proposal,
        score_input: Questions.score_inputs(@family),
        low_band: AshJudgments.Calibration.FamilyConfig.low_band(@family)
      )

    draft =
      Definition.create!(%{key: key, name: key, xml: xml}, authorize?: false, tenant: platform.id)

    certification =
      BandTableCertification
      |> Ash.Changeset.for_create(
        :record,
        %{
          definition_key: key,
          definition_version: to_string(draft.version),
          content_hash: draft.content_hash,
          family: @family,
          calibration_run_id: run.id,
          certified_by: to_string(ctx.person.email)
        },
        actor: ctx.person,
        tenant: ctx.org
      )
      |> Ash.create!()

    assert {:ok, %{status: :published}} =
             BandTablePublication.publish(
               %{
                 family: @family,
                 model_digest: run.model_digest,
                 runtime_version: run.runtime_version,
                 region: "ca"
               },
               certification,
               run,
               actor: SystemActor.process(),
               tenant: platform.id
             )
  end

  defp band(ctx, name, p_true, unit \\ "x") do
    question = Questions.declared(name)
    judgment = record!(tenant: ctx.org)

    Step.band(
      [
        %{
          question: question,
          answer: %AshAi.Evaluate.Noul{probability: p_true},
          observation_id: judgment.id
        }
      ],
      family: @family,
      tenant: ctx.org,
      subject: %{
        "type" => Standards.subject_type(),
        "id" => "ash_enterprise:lib/#{unit}.ex##{name}"
      },
      predicate: question.question_id,
      holds_value: Questions.fetch!(name).holds_value
    )
  end

  defp run_attrs do
    %{
      family: @family,
      question_hashes:
        Enum.map([:hs1_lead_with_outcome_or_ask], &Questions.declared(&1).question_hash),
      model_version: "winnow:e4b",
      model_digest: "sha256:" <> String.duplicate("b", 64),
      runtime_version: "ollaya-0.9.0",
      eval_set_hash: "sha256:" <> String.duplicate("c", 64),
      region: "ca",
      n: 2,
      n_per_class: %{},
      metrics: %{},
      ece: "0.03",
      brier: "0.08",
      conformal_thresholds: %{"0.016" => %{"threshold" => "0.9"}},
      source: :eval_set,
      created_by: "calibration-harness",
      observations_digest: "sha256:" <> String.duplicate("d", 64),
      pass_bar: %{},
      finished_at: DateTime.utc_now()
    }
  end
end
