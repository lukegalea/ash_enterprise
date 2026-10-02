defmodule AshEnterprise.SystemOne.BandingTest do
  @moduledoc """
  The host banding pipeline (AST-92 host wiring): flatten → resolve →
  evaluate → record → route, against a stub band-table resolver.

  Proves the RFC §7.1 record contract on the host: every banding output is
  an input (§6.1), matched_rule_ids are POPULATED from the recorded
  Evaluation (empty is a refusal that writes no row), fact_value is
  admit-only, the bands route correctly through the materialiser (admit
  materialises, review creates no fact, omit supersedes), and the banding
  event carries tenant + correlation attribution (the ledger's AC-4
  pattern).
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.SystemOne.Support

  require Ash.Query

  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.SystemOne.Banding
  alias AshEnterprise.SystemOne.Banding.Step
  alias AshEnterprise.SystemOne.Fact
  alias AshEnterprise.SystemOne.TestSupport.Standard
  alias AshJudgments.Registry.Info

  setup do
    Correlation.start_new()
    %{org: Ash.UUID.generate()}
  end

  @question Info.question(Standard, :commit_message_imperative)

  defp answer do
    %{
      question: @question,
      answer: %{
        value: "imperative",
        probabilities: %{"imperative" => 0.9, "other" => 0.08, "insufficient" => 0.02},
        confidence: 0.9
      },
      observation_id: Ash.UUID.generate()
    }
  end

  defp band_table_ref do
    %{
      "definition_key" => "judgments_band_standards_commits",
      "definition_version" => "1",
      "content_hash" => "sha256:" <> String.duplicate("a", 64),
      "definition_id" => Ash.UUID.generate(),
      "tenant_fork" => nil
    }
  end

  defp stub_resolver(outputs, matched_rule_ids, overrides \\ []) do
    evaluation =
      %{
        band_table: band_table_ref(),
        outputs: outputs,
        matched_rule_ids: matched_rule_ids,
        decision_evaluation_id: Ash.UUID.generate()
      }
      |> Map.merge(Map.new(overrides))

    fn _family, _tenant, _inputs -> {:ok, evaluation} end
  end

  defp band_opts(org, overrides \\ []) do
    [
      family: "standards_commits",
      tenant: org,
      subject: %{"type" => "commit", "id" => "commit-1"},
      predicate: @question.question_id,
      risk_tier: "low",
      jurisdiction: "EX-1"
    ]
    |> Keyword.merge(overrides)
  end

  defp facts_for(org, subject_id) do
    Fact
    |> Ash.Query.filter(subject_id == ^subject_id)
    |> Ash.read!(authorize?: false)
  end

  describe "the pipeline (stub band-table resolver)" do
    test "admit records the banding with populated matched_rule_ids and materialises the fact",
         ctx do
      resolver =
        stub_resolver(
          %{"band" => "admit", "fact_value" => true, "reason_code" => "auto_pass"},
          ["DecisionRule_1"]
        )

      correlation_id = Ash.UUID.generate()

      result =
        Correlation.with_correlation(correlation_id, fn ->
          Step.band([answer()], band_opts(ctx.org, resolver: resolver))
        end)

      assert {:ok, %{banding: banding, band: :admit, materialisation: :materialised}} = result

      # Every output an input, recorded never recomputed (§6.1).
      assert banding.band == :admit
      assert banding.matched_rule_ids == ["DecisionRule_1"]
      assert banding.fact_value == true
      assert banding.reason_code == "auto_pass"
      assert banding.band_table["definition_key"] == "judgments_band_standards_commits"
      assert banding.decision_evaluation_id
      assert banding.inputs["commit_message_imperative__p_imperative"] == "0.9"
      assert banding.inputs["family"] == "standards_commits"
      assert banding.mode == :live

      # The admission side: the fact is materialised at grant grade, with
      # the banding id as admission provenance.
      assert [fact] = facts_for(ctx.org, "commit-1")
      assert fact.value == true
      assert fact.holds == true
      assert fact.predicate == @question.question_id
      assert fact.admission_grade == :grant
      assert fact.admission_id == banding.id
      assert is_nil(fact.superseded_by)
    end

    test "review records the banding, materialises no fact", ctx do
      resolver =
        stub_resolver(%{"band" => "review", "reason_code" => "borderline"}, ["DecisionRule_2"])

      assert {:ok, %{band: :review, materialisation: :no_fact, banding: banding}} =
               Step.band([answer()], band_opts(ctx.org, resolver: resolver))

      assert banding.fact_value == nil
      assert banding.matched_rule_ids == ["DecisionRule_2"]
      assert facts_for(ctx.org, "commit-1") == []
    end

    test "omit supersedes the current fact (the predicate returns to unknown)", ctx do
      resolver =
        stub_resolver(
          %{"band" => "admit", "fact_value" => true, "reason_code" => "auto_pass"},
          ["DecisionRule_1"]
        )

      assert {:ok, %{banding: admitted, materialisation: :materialised}} =
               Step.band([answer()], band_opts(ctx.org, resolver: resolver))

      assert [_] = facts_for(ctx.org, "commit-1")

      omit_resolver =
        stub_resolver(%{"band" => "omit", "reason_code" => "withdrawn"}, ["DecisionRule_3"])

      assert {:ok, %{band: :omit, materialisation: :superseded}} =
               Step.band(
                 [answer()],
                 band_opts(ctx.org, resolver: omit_resolver, banding_id: Ash.UUID.generate())
               )

      [fact] = facts_for(ctx.org, "commit-1")
      refute is_nil(fact.superseded_by), "the current fact is superseded, never deleted"
    end

    test "matched_rule_ids empty is a refusal: no banding row is written", ctx do
      resolver = stub_resolver(%{"band" => "admit", "fact_value" => true}, [])

      assert {:refusal, refusal} = Step.band([answer()], band_opts(ctx.org, resolver: resolver))
      assert refusal.reason =~ "matched_rule_ids"
      assert Banding |> Ash.read!(tenant: ctx.org, authorize?: false) == []
      assert facts_for(ctx.org, "commit-1") == []
    end
  end

  describe "attribution (AC-4, the ledger's pattern)" do
    test "a banding create produces an AshEvents event attributed to tenant and correlation" do
      org = Ash.UUID.generate()
      correlation_id = Ash.UUID.generate()

      resolver =
        stub_resolver(%{"band" => "admit", "fact_value" => true, "reason_code" => "auto_pass"}, [
          "DecisionRule_1"
        ])

      banding =
        Correlation.with_correlation(correlation_id, fn ->
          {:ok, %{banding: banding}} =
            Step.band([answer()], band_opts(org, resolver: resolver))

          banding
        end)

      [event] =
        EventLog
        |> Ash.Query.filter(action == ^:record and record_id == ^banding.id)
        |> Ash.read!(authorize?: false)

      assert event.resource == Banding
      assert event.metadata["correlation_id"] == correlation_id
      assert event.organization_id == org
      assert event.user_id == nil
    end
  end
end
