defmodule AshEnterprise.Provenance.JudgedFactTest do
  @moduledoc """
  A judged fact explains itself (ADR 0078, section 4): the banding that admitted
  it, the DMN evaluation and the rules it matched, the observations the band
  table read, and the atoms those cited — every record read as the reader, so a
  record the reader may not read is an `:unreadable` gap that names nothing.
  """

  use AshEnterprise.DataCase, async: false

  @moduletag evidence: true

  import AshEnterprise.SystemOne.Support, only: [evidence_document: 1, record!: 1]
  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 1, member!: 3]

  require Ash.Query

  alias AshEnterprise.Decisions.Evaluation
  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Provenance
  alias AshEnterprise.SystemOne.{Banding, Fact, Judgment}
  alias AshEnterprise.SystemOne.Banding.Step
  alias AshEnterprise.SystemOne.TestSupport.Standard
  alias AshEnterprise.Test.Quality.BandTables
  alias AshJudgments.Facts.Materialiser
  alias AshJudgments.Registry.Info

  @question Info.question(Standard, :commit_message_imperative)
  @grants [{Fact, :read, :global}, {Banding, :read, :global}, {Evaluation, :read, :global}] ++
            [{Judgment, :read, :global}]

  setup do
    Correlation.start_new()
    operator = tenant!(operator?: true)
    %{operator: operator, definition: BandTables.published!()}
  end

  # One admitted fact with the whole chain behind it. `evaluation` overrides
  # what the recorded evaluation says.
  defp judged_fact!(ctx, evaluation \\ %{}) do
    tenant = ctx.operator.tenant

    document =
      evidence_document([
        "Fix the bug #{System.unique_integer([:positive])}",
        "Add a test #{System.unique_integer([:positive])}"
      ])

    observation = record!(tenant: tenant, atom_ids: document.atom_ids)

    recorded =
      Evaluation.create!(
        Map.merge(
          %{
            definition_id: ctx.definition.id,
            definition_key: ctx.definition.key,
            definition_version: ctx.definition.version,
            matched_rule_ids: ["rule_imperative"],
            hit_policy: "UNIQUE"
          },
          evaluation
        ),
        tenant: tenant,
        authorize?: false
      )

    resolver = fn _family, _tenant, _inputs ->
      {:ok,
       %{
         band_table: %{
           "definition_key" => ctx.definition.key,
           "definition_version" => "1",
           "content_hash" => "sha256:" <> String.duplicate("a", 64),
           "definition_id" => ctx.definition.id,
           "tenant_fork" => nil
         },
         outputs: %{"band" => "admit", "fact_value" => true, "reason_code" => "auto_pass"},
         matched_rule_ids: ["rule_imperative"],
         decision_evaluation_id: recorded.id
       }}
    end

    answer = %{
      question: @question,
      answer: %{
        value: "imperative",
        probabilities: %{"imperative" => 0.9, "other" => 0.08, "insufficient" => 0.02},
        confidence: 0.9
      },
      observation_id: observation.id
    }

    subject_id = "commit-#{System.unique_integer([:positive])}"

    assert {:ok, %{banding: banding}} =
             Step.band([answer],
               family: "standards_commits",
               tenant: tenant,
               subject: %{"type" => "commit", "id" => subject_id},
               predicate: @question.question_id,
               risk_tier: "low",
               jurisdiction: "EX-1",
               resolver: resolver
             )

    [fact] =
      Fact |> Ash.Query.filter(subject_id == ^subject_id) |> Ash.read!(authorize?: false)

    %{
      fact: fact,
      banding: banding,
      evaluation: recorded,
      observation: observation,
      document: document
    }
  end

  defp reader!(ctx, grants \\ @grants),
    do: member!(ctx.operator, "Judged reader #{System.unique_integer([:positive])}", grants)

  defp explain(reader, fact) do
    {:ok, %{explanation: explanation}} =
      Provenance.explain("#{Provenance.base()}/fact/#{fact.id}#value",
        actor: reader.actor,
        tenant: reader.tenant
      )

    explanation
  end

  defp relations(explanation, relation),
    do: Enum.filter(explanation.steps, &(&1.relation == relation))

  defp kinds(explanation), do: Enum.map(explanation.gaps, & &1.kind)

  test "the chain runs from the fact through the matched rule to the atoms", ctx do
    chain = judged_fact!(ctx)
    explanation = explain(reader!(ctx), chain.fact)

    assert [generated] = relations(explanation, :was_generated_by)
    assert generated.entity.type == "fact"
    assert generated.activity =~ "banding:#{chain.banding.id}"

    assert [used] = relations(explanation, :used)
    assert used.summary =~ "rule_imperative"

    atom_steps =
      explanation
      |> relations(:was_derived_from)
      |> Enum.filter(&(&1.antecedent.type == "addressed_atom"))

    assert Enum.sort(Enum.map(atom_steps, & &1.antecedent.id)) ==
             Enum.sort(chain.document.atom_ids)

    assert explanation.gaps == []
    refute inspect(explanation) =~ "Fix the bug"
  end

  test "an evaluation that matched no rule is an answer, one that failed is a gap", ctx do
    none = judged_fact!(ctx, %{matched_rule_ids: [], hit_policy: "UNIQUE"})
    explanation = explain(reader!(ctx), none.fact)

    assert [%{summary: "no rule matched" <> _}] = relations(explanation, :used)
    assert explanation.gaps == []

    failed =
      judged_fact!(ctx, %{
        matched_rule_ids: [],
        hit_policy: "UNIQUE",
        error: %{"message" => "secret detail"}
      })

    explanation = explain(reader!(ctx), failed.fact)

    assert kinds(explanation) == [:failed]
    refute inspect(explanation) =~ "secret detail"

    unrecorded = judged_fact!(ctx, %{matched_rule_ids: [], hit_policy: nil})
    explanation = explain(reader!(ctx), unrecorded.fact)

    assert kinds(explanation) == [:not_recorded]
  end

  test "an atom that was shredded is erased, and says nothing else of it", ctx do
    chain = judged_fact!(ctx)
    assert :ok = AshEvidence.Domain.destroy_document_version(chain.document.version_id)

    explanation = explain(reader!(ctx), chain.fact)

    assert kinds(explanation) == [:erased, :erased]

    assert [] ==
             explanation
             |> relations(:was_derived_from)
             |> Enum.filter(&(&1.antecedent.type == "addressed_atom"))

    assert [%{relation: :used}] = relations(explanation, :used)
  end

  describe "what the reader may not read is a gap that names nothing" do
    test "without the banding grant the chain stops at the fact", ctx do
      chain = judged_fact!(ctx)

      explanation =
        explain(reader!(ctx, List.delete(@grants, {Banding, :read, :global})), chain.fact)

      assert :unreadable in kinds(explanation)
      assert relations(explanation, :used) == []
      refute inspect(explanation) =~ chain.banding.id
      refute inspect(explanation) =~ chain.evaluation.id
    end

    test "without the evaluation grant the observations still answer", ctx do
      chain = judged_fact!(ctx)

      explanation =
        explain(reader!(ctx, List.delete(@grants, {Evaluation, :read, :global})), chain.fact)

      assert kinds(explanation) == [:unreadable]
      assert relations(explanation, :used) == []
      assert [_, _, _] = relations(explanation, :was_derived_from)
      refute inspect(explanation) =~ chain.evaluation.id
    end

    test "without the ledger grant no observation or atom is named", ctx do
      chain = judged_fact!(ctx)

      explanation =
        explain(reader!(ctx, List.delete(@grants, {Judgment, :read, :global})), chain.fact)

      assert :unreadable in kinds(explanation)
      assert relations(explanation, :was_derived_from) == []
      refute inspect(explanation) =~ chain.observation.id
      assert Enum.all?(chain.document.atom_ids, &(not (inspect(explanation) =~ &1)))
    end

    test "a reader who cannot read the fact is told it is not found", ctx do
      chain = judged_fact!(ctx)
      reader = reader!(ctx, [])

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Provenance.explain("#{Provenance.base()}/fact/#{chain.fact.id}#value",
                 actor: reader.actor,
                 tenant: reader.tenant
               )
    end
  end

  test "a fact with no recorded admission is not recorded, not guessed", ctx do
    subject_id = "replayed-#{System.unique_integer([:positive])}"

    assert {:ok, :materialised} =
             Materialiser.materialise(%{
               result: :admitted,
               subject: %{"type" => "commit", "id" => subject_id},
               predicate: "commit_message_imperative",
               value: "imperative",
               holds: true,
               grade: :grant,
               admission_id: nil,
               effective_at: ~U[2026-06-01 12:00:00Z]
             })

    [fact] = Fact |> Ash.Query.filter(subject_id == ^subject_id) |> Ash.read!(authorize?: false)
    explanation = explain(reader!(ctx), fact)

    assert :not_recorded in kinds(explanation)
    assert relations(explanation, :used) == []
  end
end
