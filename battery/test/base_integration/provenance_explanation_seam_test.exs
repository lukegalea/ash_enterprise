defmodule Battery.Integration.ProvenanceExplanationSeamTest do
  @moduledoc """
  Scenario — provenance: one explanation across four packages.

  A fact materialised by ash_judgments from a banding over an ash_decisions
  evaluation and a judged observation that cites ash_evidence atoms is
  explained on the ash_provenance contract: `AshJudgments.Explain.fact/3` walks
  fact -> banding -> evaluation -> observation, and hands the observation's
  atoms to `AshEvidence.Explanation.provenance/3`. The result exports as PROV-O.

  Negative halves come first: every link the reader cannot see, or that is not
  there, is a typed gap and never a silent drop, an unreadable gap names nothing,
  and a cut answer says so in its bounds.
  """

  use ExUnit.Case, async: false

  alias AshJudgments.Bridge.Dmn
  alias AshJudgments.Registry.Info
  alias AshProvenance.Explanation

  require Ash.Query

  @base "https://battery.example/explain"

  @battery_tables [
    Battery.SystemOne.Judgment,
    Battery.SystemOne.Fact,
    Battery.SystemOne.Banding,
    Battery.Events.EventLog,
    Battery.SystemOne.CaseFile,
    Battery.Decisions.Definition,
    Battery.Decisions.Evaluation
  ]

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Battery.Repo, sandbox: false)
    Ecto.Adapters.SQL.Sandbox.checkout(AshEvidence.Repo, sandbox: false)

    Enum.each(@battery_tables, &Battery.Repo.delete_all(&1))

    for table <- ~w(addressed_atoms parse_runs document_versions) do
      AshEvidence.Repo.query!("DELETE FROM " <> table)
    end

    previous = System.get_env("JUDGE_BASE_URL")
    System.put_env("JUDGE_BASE_URL", "http://127.0.0.1:11435")
    System.put_env("JUDGE_API_KEY", "local")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("JUDGE_BASE_URL")
        old -> System.put_env("JUDGE_BASE_URL", old)
      end
    end)

    :ok
  end

  # The recorded chain of the judgment_banding_evidence scenario, with the fact's
  # admission_id naming the banding (the link `Explain.fact/3` verifies).
  defp chain!(mode \\ :live) do
    bytes = "BATTERY-DOC-PROV\n" <> String.duplicate("clause body ", 32)
    doc_hash = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    version = AshEvidence.Domain.ingest_document!("text/plain", bytes, doc_hash)
    run = AshEvidence.Domain.start_parse_run!(version.id, "battery-parse-instrument", %{})

    atoms =
      for {seq, text} <- [{1, "Coverage limit is 500000 USD"}, {2, "The policy ends 2027-03-31"}] do
        AshEvidence.Domain.ingest_atom!(version.id, run.id, seq, text, :line)
      end

    atom_ids = Enum.map(atoms, & &1.id)
    question = Info.question(Battery.SystemOne.CaseFile, :evidence_support)

    answer =
      Battery.SystemOne.CaseFile
      |> Ash.ActionInput.for_action(:judge_evidence_support, %{
        "input" => %{"text" => "Coverage limit is 500000 USD.", "atom_ids" => atom_ids}
      })
      |> Ash.run_action!(context: %{judgments: %{req_llm: Battery.FakeReqLLM}})

    [observation] =
      Battery.SystemOne.Judgment
      |> Ash.Query.for_read(:latest_answered, %{question_id: question.question_id})
      |> Ash.read!()

    band_definition =
      AshDecisions.BandTable.land!(
        Battery.Decisions.Definition,
        Battery.Fixtures.band_table_dmn()
      )

    inputs =
      Dmn.inputs(
        [%{question: question, answer: answer, observation_id: observation.id}],
        family: "case_review",
        risk_tier: "standard",
        jurisdiction: "ca"
      )

    {:ok, result} =
      AshDecisions.Evaluator.evaluate(band_definition, inputs,
        evaluation_resource: Battery.Decisions.Evaluation
      )

    evaluation =
      Battery.Decisions.Evaluation
      |> Ash.Query.filter(definition_id == ^band_definition.id)
      |> Ash.read_one!()

    banding =
      Battery.SystemOne.Banding
      |> Ash.Changeset.for_create(:record, %{
        observation_ids: [observation.id],
        band: :admit,
        fact_value: %{"value" => "supports"},
        matched_rule_ids: result.matched_rule_ids,
        band_table: %{
          "definition_key" => band_definition.key,
          "definition_version" => band_definition.version,
          "content_hash" => band_definition.content_hash,
          "definition_id" => band_definition.id,
          "tenant_fork" => nil
        },
        decision_evaluation_id: evaluation.id,
        inputs: inputs,
        mode: mode
      })
      |> Ash.create!()

    subject = %{"type" => "Battery.SystemOne.CaseFile", "id" => Ecto.UUID.generate()}

    {:ok, _} =
      AshJudgments.Facts.Materialiser.materialise(%{
        result: :admitted,
        subject: subject,
        predicate: question.question_id,
        value: "supports",
        holds: true,
        grade: :grant,
        admission_id: banding.id,
        id: observation.id,
        subject_state_digest: observation.state_digest
      })

    [fact] =
      Battery.SystemOne.Fact
      |> Ash.Query.for_read(:for_subject, %{subject: subject, predicate: question.question_id})
      |> Ash.read!()

    %{
      fact: fact,
      banding: banding,
      evaluation: evaluation,
      observation: observation,
      atom_ids: atom_ids,
      atoms: atoms
    }
  end

  defp links(c),
    do: %{banding: c.banding, evaluation: c.evaluation, observations: [c.observation]}

  defp explain!(fact, links, extra \\ []) do
    {:ok, explanation} =
      AshJudgments.Explain.fact(
        fact,
        links,
        [base: @base, atoms: &AshEvidence.Explanation.provenance(&1, &2, authorize?: false)] ++
          extra
      )

    explanation
  end

  defp kinds(%Explanation{gaps: gaps}), do: gaps |> Enum.map(& &1.kind) |> Enum.sort()
  defp relations(%Explanation{steps: steps}), do: Enum.map(steps, & &1.relation)

  describe "where the answer stops" do
    test "a fact with no admission is not_recorded, never an invented chain" do
      c = chain!()
      e = explain!(%{c.fact | admission_id: nil}, links(c))

      assert e.steps == []
      assert kinds(e) == [:not_recorded]
    end

    test "an unreadable banding is an unreadable gap that carries nothing" do
      c = chain!()
      e = explain!(c.fact, %{links(c) | banding: :unreadable})

      assert e.steps == []
      assert kinds(e) == [:unreadable]
      assert [%{receipt: nil, at: nil, summary: nil}] = e.gaps
    end

    test "a missing evaluation is not_recorded, and the rest of the chain still answers" do
      c = chain!()
      e = explain!(c.fact, %{links(c) | evaluation: nil})

      assert :not_recorded in kinds(e)
      assert :was_generated_by in relations(e)
      assert :was_derived_from in relations(e)
      refute :used in relations(e)
    end

    test "an unreadable observation is a gap, never a dropped step" do
      c = chain!()
      e = explain!(c.fact, %{links(c) | observations: :unreadable})

      assert kinds(e) == [:unreadable]
      assert length(e.steps) == 2
    end

    test "an erased atom is an erased gap beside the atoms that remain" do
      c = chain!()
      [gone | kept] = c.atom_ids

      AshEvidence.Repo.query!("DELETE FROM addressed_atoms WHERE id = $1", [
        Ecto.UUID.dump!(gone)
      ])

      e = explain!(c.fact, links(c))

      assert kinds(e) == [:erased]
      derived = for s <- e.steps, s.relation == :was_derived_from, do: s.antecedent.id
      assert Enum.all?(kept, &(&1 in derived))
      refute gone in derived
    end

    test "a short step cap cuts the answer and says so" do
      c = chain!()
      e = explain!(c.fact, links(c), max_steps: 2)

      assert e.bounds.cut? == true
      assert e.bounds.step_count == 2
      assert length(e.steps) == 2
    end
  end

  describe "the whole chain" do
    test "fact, banding, evaluation, observation and atoms, with no gap" do
      c = chain!()
      e = explain!(c.fact, links(c))

      assert e.gaps == []
      assert e.bounds.cut? == false
      assert e.subject.type == "fact" and e.subject.attribute == "value"

      relations = relations(e)
      assert :was_generated_by in relations
      assert :used in relations
      assert length(Enum.filter(relations, &(&1 == :was_derived_from))) == 1 + length(c.atom_ids)

      # the plan on the generating step is the band table that decided
      [gen] = Enum.filter(e.steps, &(&1.relation == :was_generated_by))
      assert gen.plan.key == "bands_case_review"
      assert gen.execution_context == :live

      # the atoms are the evidence package's, cited by the observation
      atoms =
        for s <- e.steps,
            s.antecedent && s.antecedent.type == "addressed_atom",
            do: s.antecedent.id

      assert Enum.sort(atoms) == Enum.sort(c.atom_ids)
    end

    test "a shadow banding keeps its execution context on the explanation" do
      c = chain!(:shadow)
      e = explain!(c.fact, links(c))

      [gen] = Enum.filter(e.steps, &(&1.relation == :was_generated_by))
      assert gen.execution_context == :shadow
    end

    test "the explanation exports as PROV-O" do
      c = chain!()
      jsonld = c.fact |> explain!(links(c)) |> AshProvenance.Export.ProvO.to_jsonld()

      assert is_map(jsonld)
      assert {:ok, _} = Jason.encode(jsonld)
    end
  end
end
