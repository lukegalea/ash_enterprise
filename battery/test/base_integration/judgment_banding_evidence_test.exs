defmodule Battery.Integration.JudgmentBandingEvidenceTest do
  @moduledoc """
  Scenario 1 — judgment → banding → evidence.

  The cross-substrate seam: an ash_evidence parse run addresses atoms; a
  System One EVIDENCE question is judged over them and the observation
  cites the atoms; the host's banding step flattens the answer
  (`AshJudgments.Bridge.Dmn.inputs/2`), evaluates a PUBLISHED ash_decisions
  band table, and records the banding with the decision's identity; the
  admitted band materialises a fact whose provenance ties back to the
  recorded observation.

  Nothing here re-asserts a single dep's internals: every assertion is
  about ids, hashes and digests CROSSING between the three substrates.
  """

  use ExUnit.Case, async: false

  alias AshEvidence.AddressedAtom
  alias AshJudgments.Bridge.Dmn
  alias AshJudgments.Registry.{Canonical, Info}

  require Ash.Query

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

    # The profile registry resolves :test_local from the env at call time.
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

  test "an evidence parse run backs a judged, banded, materialised fact" do
    # ── 1. ash_evidence: version → parse run → addressed atoms ───────────
    bytes = "BATTERY-DOC-0001\n" <> String.duplicate("clause body ", 32)
    doc_hash = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    version = AshEvidence.Domain.ingest_document!("text/plain", bytes, doc_hash)
    run = AshEvidence.Domain.start_parse_run!(version.id, "battery-parse-instrument", %{})

    atoms = [
      AshEvidence.Domain.ingest_atom!(version.id, run.id, 1, "Coverage limit is 500000 USD"),
      AshEvidence.Domain.ingest_atom!(
        version.id,
        run.id,
        2,
        "The policy terminates on 2027-03-31"
      )
    ]

    atom_ids = Enum.map(atoms, & &1.id)

    # the atoms belong to THIS version and THIS parse run
    assert Enum.all?(atoms, &(&1.document_version_id == version.id))
    assert Enum.all?(atoms, &(&1.parse_run_id == run.id))
    assert %AddressedAtom{} = hd(atoms)

    # ── 2. the evidence-backed judge records an observation citing them ──
    question = Info.question(Battery.SystemOne.CaseFile, :evidence_support)

    answer =
      Battery.SystemOne.CaseFile
      |> Ash.ActionInput.for_action(:judge_evidence_support, %{
        "input" => %{
          "text" => "Coverage limit is 500000 USD; the policy terminates on 2027-03-31.",
          "atom_ids" => atom_ids
        }
      })
      |> Ash.run_action!(context: %{judgments: %{req_llm: Battery.FakeReqLLM}})

    assert answer.value == :supports
    assert answer.source_ids == atom_ids

    [observation] =
      Battery.SystemOne.Judgment
      |> Ash.Query.for_read(:latest_answered, %{question_id: question.question_id})
      |> Ash.read!()

    # THE SEAM: the observation cites the evidence atoms, and its identity
    # is the declared question's identity.
    assert observation.atom_ids == atom_ids
    assert observation.question_hash == Info.hash(Battery.SystemOne.CaseFile, :evidence_support)
    assert observation.answer_kind == :evidence
    assert observation.mode == :live

    # ── 3. banding: flatten, evaluate the published band table, record ──
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

    assert inputs["evidence_support__p_supports"] == "0.9"
    assert inputs["evidence_support__present"] == "true"
    assert inputs["evidence_support__observation_id"] == observation.id

    {:ok, result} =
      AshDecisions.Evaluator.evaluate(band_definition, inputs,
        evaluation_resource: Battery.Decisions.Evaluation
      )

    # a single-output band table answers with the scalar
    assert result.outputs == "admit"
    assert result.matched_rule_ids == ["rule_admit"]
    assert result.definition_key == "bands_case_review"

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
        mode: :live
      })
      |> Ash.create!()

    # ── 4. the admitted band materialises the fact ────────────────────────
    subject = %{"type" => "Battery.SystemOne.CaseFile", "id" => Ecto.UUID.generate()}

    decision = %{
      result: :admitted,
      subject: subject,
      predicate: question.question_id,
      value: "supports",
      holds: true,
      grade: :grant,
      admission_id: observation.id,
      id: observation.id,
      subject_state_digest: observation.state_digest
    }

    {:ok, _verdict} = AshJudgments.Facts.Materialiser.materialise(decision)

    [fact] =
      Battery.SystemOne.Fact
      |> Ash.Query.for_read(:for_subject, %{subject: subject, predicate: question.question_id})
      |> Ash.read!()

    assert fact.holds == true
    assert fact.admission_grade == :grant

    # ── the integration property: the digests tie the chain together ──────
    # observation ↔ evidence atoms
    assert observation.atom_ids == atom_ids
    assert Enum.map(atoms, & &1.document_version_id) == [version.id, version.id]

    # observation ↔ question identity
    assert observation.question_id == question.question_id
    assert observation.question_hash == question.question_hash

    # fact ↔ observation (admission provenance + the state the judge saw)
    assert fact.admission_id == observation.id
    assert fact.subject_state_digest == observation.state_digest

    # banding ↔ the ash_decisions definition + evaluation it decided on
    assert banding.observation_ids == [observation.id]
    assert banding.band_table["content_hash"] == band_definition.content_hash
    assert banding.band_table["definition_key"] == band_definition.key
    assert banding.decision_evaluation_id == evaluation.id
    assert banding.matched_rule_ids == evaluation.matched_rule_ids
    assert banding.inputs["evidence_support__p_supports"] == "0.9"

    # the recorded state digest is the canonical digest of the projected
    # state the instrument was handed
    state = %{
      "text" => "Coverage limit is 500000 USD; the policy terminates on 2027-03-31.",
      "atom_ids" => atom_ids
    }

    assert observation.state_digest == Canonical.digest(Canonical.encode(state))
  end

  test "a band below the threshold refuses to materialise a fact" do
    # The negative half of the seam: a low-support answer bands to :review,
    # and §7.1's admit-only contract means no fact value, no fact.
    bytes = "BATTERY-DOC-0002\n" <> String.duplicate("clause body ", 32)
    doc_hash = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    version = AshEvidence.Domain.ingest_document!("text/plain", bytes, doc_hash)
    run = AshEvidence.Domain.start_parse_run!(version.id, "battery-parse-instrument", %{})

    atom =
      AshEvidence.Domain.ingest_atom!(version.id, run.id, 1, "The summary page is unreadable")

    question = Info.question(Battery.SystemOne.CaseFile, :evidence_support)

    # A contradictory-leaning instrument reply, banding to :review.
    low_answer = %AshJudgments.Evaluate.Evidence{
      value: :insufficient,
      probabilities: %{"supports" => 0.3, "insufficient" => 0.7},
      confidence: 0.9,
      source_ids: [atom.id]
    }

    inputs =
      Dmn.inputs(
        [%{question: question, answer: low_answer, observation_id: Ecto.UUID.generate()}],
        family: "case_review",
        risk_tier: "standard",
        jurisdiction: "ca"
      )

    band_definition =
      AshDecisions.BandTable.land!(
        Battery.Decisions.Definition,
        Battery.Fixtures.band_table_dmn()
      )

    {:ok, result} =
      AshDecisions.Evaluator.evaluate(band_definition, inputs,
        evaluation_resource: Battery.Decisions.Evaluation
      )

    assert result.outputs == "review"

    # §7.1: a review banding proposes NO fact value — the validation on the
    # banding fragment refuses the record that tries to smuggle one in.
    assert_raise Ash.Error.Invalid, ~r/fact_value/i, fn ->
      Battery.SystemOne.Banding
      |> Ash.Changeset.for_create(:record, %{
        observation_ids: [Ecto.UUID.generate()],
        band: :review,
        fact_value: %{"value" => "insufficient"},
        matched_rule_ids: result.matched_rule_ids,
        band_table: %{
          "definition_key" => band_definition.key,
          "definition_version" => band_definition.version,
          "content_hash" => band_definition.content_hash,
          "definition_id" => band_definition.id,
          "tenant_fork" => nil
        },
        decision_evaluation_id: Ecto.UUID.generate(),
        inputs: inputs,
        mode: :live
      })
      |> Ash.create!()
    end

    # and the :review result materialises nothing (§7.2: an open review
    # reads as unknown by absence).
    subject = %{"type" => "Battery.SystemOne.CaseFile", "id" => Ecto.UUID.generate()}

    assert {:ok, :no_fact} =
             AshJudgments.Facts.Materialiser.materialise(%{
               result: :review,
               subject: subject,
               predicate: question.question_id,
               grade: :grant,
               admission_id: Ecto.UUID.generate()
             })
  end
end
