defmodule Battery.Integration.JudgmentDmnSolveTest do
  @moduledoc """
  Scenario — planning: judgment fact → DMN parameter → solve → candidate.

  The cross-substrate seam: a System One EVIDENCE question is judged over
  ash_evidence atoms and its fact is materialised; a PUBLISHED ash_decisions
  definition turns that fact into a planning parameter (the buffer between
  two tasks); the parameter is pinned into an `AshOpenLineage` snapshot, with
  the DMN's key, version and content hash; a backend (the package's Fake)
  solves over exactly that snapshot; and the candidate it proposes is tied,
  through the sealed snapshot, to the decision VERSION that fired.

  Asserted: the snapshot names the definition the evaluation recorded (same
  version, same content hash, same matched rule); a new policy version changes
  the parameter, the candidate and the digest with no code change, while the
  earlier candidate still replays and still names the version it ran on; and
  a fact the judge never produced leaves the parameter unresolved: the
  snapshot says so and nothing is solved.

  The model is a synthetic stand-in (a buffered day), the DMN a synthetic
  policy, the tasks synthetic ids. Only ids, hashes and digests cross between
  the substrates.
  """

  use ExUnit.Case, async: false

  import Battery.PlanningKit

  alias AshEvidence.AddressedAtom
  alias AshJudgments.Registry.Info
  alias AshOpenLineage.Snapshot
  alias AshOpenLineage.Snapshot.{Definition, Input}
  alias AshPlanning.Snapshot, as: PlanSnapshot
  alias AshPlanning.Validators.Intervals
  alias Battery.Bpmn.DecisionResolver
  alias Battery.Decisions.Evaluation
  alias Battery.PlanningKit.CandidateRow
  alias Battery.SystemOne.{CaseFile, Fact}

  require Ash.Query

  @key "battery_planning_buffer"
  @model "var 0..1440: start_a; var 0..1440: start_b; constraint start_b >= start_a + 30 + buffer;"
  @question :evidence_support

  @tasks [%{"id" => "task-a", "minutes" => 30}, %{"id" => "task-b", "minutes" => 45}]

  # The synthetic buffer policy: the minutes kept between two tasks, by what
  # the judged fact says. Version 2 tightens the buffer for a supported claim.
  # UNIQUE, no default rule: an absent fact matches no row and refuses.
  defp buffer_dmn(policy_version) when policy_version in [1, 2] do
    supports = if policy_version == 1, do: 15, else: 10

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <definitions xmlns="https://www.omg.org/spec/DMN/20230324/MODEL/"
                 xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                 id="battery_planning_buffer_definitions"
                 name="#{@key}"
                 namespace="https://battery.test/#{@key}"
                 expressionLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/"
                 typeLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/">
      <inputData id="input_evidence_support" name="evidence_support">
        <variable id="var_evidence_support" name="evidence_support" typeRef="string"/>
      </inputData>
      <decision id="decision_#{@key}" name="#{@key}">
        <variable id="var_#{@key}" name="#{@key}" typeRef="number"/>
        <informationRequirement id="req_evidence_support">
          <requiredInput href="#input_evidence_support"/>
        </informationRequirement>
        <decisionTable id="table_#{@key}" hitPolicy="UNIQUE" outputLabel="buffer_minutes">
          <input id="clause_evidence_support" label="Judged evidence support">
            <inputExpression id="expr_evidence_support" typeRef="string">
              <text>evidence_support</text>
            </inputExpression>
          </input>
          <output id="clause_buffer" name="buffer_minutes" label="buffer_minutes" typeRef="number"/>
          <rule id="rule_supports">
            <inputEntry id="rule_supports_0"><text>"supports"</text></inputEntry>
            <outputEntry id="rule_supports_1"><text>#{supports}</text></outputEntry>
          </rule>
          <rule id="rule_insufficient">
            <inputEntry id="rule_insufficient_0"><text>"insufficient"</text></inputEntry>
            <outputEntry id="rule_insufficient_1"><text>45</text></outputEntry>
          </rule>
        </decisionTable>
      </decision>
    </definitions>
    """
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Battery.Repo, sandbox: false)
    Ecto.Adapters.SQL.Sandbox.checkout(AshEvidence.Repo, sandbox: false)

    Enum.each(
      [
        Battery.SystemOne.Judgment,
        Fact,
        Battery.SystemOne.Banding,
        Battery.Events.EventLog,
        CaseFile,
        Evaluation,
        Battery.Decisions.Definition
      ],
      &Battery.Repo.delete_all(&1)
    )

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
        url -> System.put_env("JUDGE_BASE_URL", url)
      end
    end)

    :ok
  end

  # ── substrate 1: a judged, materialised fact ─────────────────────────────

  # ash_evidence parse run → evidence-backed judgment → admitted fact: the
  # same chain `judgment_banding_evidence_test` builds, up to the fact.
  defp judged_fact! do
    bytes = "BATTERY-DOC-PLAN\n" <> String.duplicate("clause body ", 32)
    version = AshEvidence.Domain.ingest_document!("text/plain", bytes, sha(bytes))
    run = AshEvidence.Domain.start_parse_run!(version.id, "battery-parse-instrument", %{})

    atoms = [
      AshEvidence.Domain.ingest_atom!(
        version.id,
        run.id,
        1,
        "Coverage limit is 500000 USD",
        :line
      ),
      AshEvidence.Domain.ingest_atom!(
        version.id,
        run.id,
        2,
        "The policy terminates on 2027-03-31",
        :line
      )
    ]

    atom_ids = Enum.map(atoms, & &1.id)
    assert %AddressedAtom{} = hd(atoms)

    question = Info.question(CaseFile, @question)

    answer =
      CaseFile
      |> Ash.ActionInput.for_action(:judge_evidence_support, %{
        "input" => %{
          "text" => "Coverage limit is 500000 USD; the policy terminates on 2027-03-31.",
          "atom_ids" => atom_ids
        }
      })
      |> Ash.run_action!(context: %{judgments: %{req_llm: Battery.FakeReqLLM}})

    [observation] =
      Battery.SystemOne.Judgment
      |> Ash.Query.for_read(:latest_answered, %{question_id: question.question_id})
      |> Ash.read!()

    assert observation.atom_ids == atom_ids
    assert answer.value == :supports

    subject = %{"type" => "Battery.SystemOne.CaseFile", "id" => Ecto.UUID.generate()}

    {:ok, _verdict} =
      AshJudgments.Facts.Materialiser.materialise(%{
        result: :admitted,
        subject: subject,
        predicate: question.question_id,
        value: "supports",
        holds: true,
        grade: :grant,
        admission_id: observation.id,
        id: observation.id,
        subject_state_digest: observation.state_digest
      })

    %{fact: current_fact!(subject, question.question_id), observation: observation}
  end

  # A fact admitted directly, for the scenarios that are not about the judge.
  defp admitted_fact!(value) do
    question = Info.question(CaseFile, @question)
    subject = %{"type" => "Battery.SystemOne.CaseFile", "id" => Ecto.UUID.generate()}
    admission = Ecto.UUID.generate()

    {:ok, _verdict} =
      AshJudgments.Facts.Materialiser.materialise(%{
        result: :admitted,
        subject: subject,
        predicate: question.question_id,
        value: value,
        holds: true,
        grade: :grant,
        admission_id: admission,
        id: admission,
        subject_state_digest: sha(value)
      })

    current_fact!(subject, question.question_id)
  end

  defp current_fact!(subject, predicate) do
    [fact] =
      Fact
      |> Ash.Query.for_read(:for_subject, %{subject: subject, predicate: predicate})
      |> Ash.read!()

    fact
  end

  # ── substrate 2: the published decision ──────────────────────────────────

  defp publish!(policy_version) do
    definition =
      Battery.Decisions.Definition.create!(%{
        key: @key,
        name: "Battery planning buffer",
        xml: buffer_dmn(policy_version)
      })

    assert definition.graph,
           "policy v#{policy_version} failed to compile: #{inspect(definition.errors)}"

    {:ok, published} = Battery.Decisions.Definition.publish(definition)
    published
  end

  defp evaluate(fact_or_nil) do
    {:ok, definition} = DecisionResolver.latest_published(@key)

    inputs = if fact_or_nil, do: %{"evidence_support" => to_string(fact_or_nil.value)}, else: %{}

    AshDecisions.Evaluator.evaluate(definition, inputs, evaluation_resource: Evaluation)
  end

  defp minutes(%Decimal{} = d), do: Decimal.to_integer(d)
  defp minutes(i) when is_integer(i), do: i

  defp minutes(other),
    do: flunk("a buffer is whole minutes, never a float or a string: #{inspect(other)}")

  # ── substrate 3: the planning snapshot, the solve and the candidate ──────

  defp fact_hash(fact) do
    canonical_hash(%{
      "predicate" => fact.predicate,
      "value" => to_string(fact.value),
      "subject_state_digest" => fact.subject_state_digest
    })
  end

  defp parameter_input(nil) do
    %Input{
      key: "fact.#{@question}",
      role: :parameter,
      status: :unresolved,
      source: nil,
      content_hash: nil
    }
  end

  defp parameter_input(fact) do
    %Input{
      key: "fact.#{@question}",
      role: :parameter,
      status: :value,
      source: %{resource: "Battery.SystemOne.Fact", id: fact.id, version_number: nil},
      content_hash: fact_hash(fact)
    }
  end

  defp snapshot(fact, result, problem_data) do
    {:ok, eff, _} = DateTime.from_iso8601("2026-11-09T08:00:00.000000Z")
    {:ok, cut, _} = DateTime.from_iso8601("2026-11-08T22:00:00.000000Z")

    {:ok, definition} = DecisionResolver.latest_published(@key)

    %Snapshot{
      id: Ecto.UUID.generate(),
      purpose: :"planning.battery",
      effective_at: eff,
      knowledge_cutoff: cut,
      world: :operational,
      authority: %{tenant: "t-battery", actor_id: "usr-battery", completeness: :full},
      inputs: [parameter_input(fact)],
      definitions: [
        %Definition{
          kind: :dmn,
          key: result.definition_key,
          version: Integer.to_string(result.definition_version),
          content_hash: definition.content_hash
        },
        %Definition{
          kind: :mzn,
          key: "battery_buffered_day",
          version: "1",
          content_hash: sha(@model)
        }
      ],
      payload_hash: canonical_hash(problem_data)
    }
    |> PlanSnapshot.seal()
  end

  # Tasks laid end to end with the buffer between them: what a solver
  # honouring the parameter proposes. (The Fake returns what it is scripted
  # to; the property under test is what the substrates pin, not the search.)
  defp layout(buffer) do
    {assignments, _cursor} =
      Enum.map_reduce(@tasks, 0, fn %{"id" => id, "minutes" => m}, cursor ->
        {%{id: id, start: cursor, end: cursor + m}, cursor + m + buffer}
      end)

    assignments
  end

  # The whole pipeline over one fact: DMN → parameter → snapshot → solve →
  # candidate. Returns what a Run row would hold: its id, sealed snapshot,
  # and the candidate it proposed.
  defp plan!(fact) do
    {:ok, result} = evaluate(fact)
    buffer = minutes(result.outputs)

    problem_data = %{"buffer_minutes" => buffer, "tasks" => @tasks}
    sealed = snapshot(fact, result, problem_data)

    {[candidate], solved} = solve!([%{assignments: layout(buffer)}], %{fake_objective: 0})
    run_id = Ecto.UUID.generate()
    row = propose!(run_id, candidate.index, candidate.data.assignments)

    %{
      run_id: run_id,
      snapshot: sealed,
      solved: solved,
      candidate: candidate,
      row: row,
      result: result,
      buffer: buffer
    }
  end

  defp evaluation_row!(definition_id) do
    Evaluation
    |> Ash.Query.filter(definition_id == ^definition_id)
    |> Ash.read_one!()
  end

  test "a judged fact sets a DMN parameter, and the candidate names the decision version that fired" do
    # ── 1. judgments: an evidence parse run backs an admitted fact ───────
    %{fact: fact} = judged_fact!()
    assert fact.holds == true and to_string(fact.value) == "supports"

    # ── 2. decisions: the published policy turns the fact into a parameter
    published = publish!(1)
    assert published.version == 1

    plan = plan!(fact)

    assert plan.buffer == 15
    assert plan.result.matched_rule_ids == ["rule_supports"]
    assert plan.result.definition_version == 1
    refute is_float(plan.result.outputs)

    evaluation = evaluation_row!(published.id)
    assert evaluation.matched_rule_ids == ["rule_supports"]
    assert evaluation.inputs == %{"evidence_support" => "supports"}

    # ── 3. planning: the snapshot pins the fact and the decision's identity
    sealed = plan.snapshot
    assert PlanSnapshot.verify(sealed)
    assert PlanSnapshot.complete?(sealed)

    assert [%Input{role: :parameter, content_hash: hash, source: %{id: fact_id}}] =
             PlanSnapshot.inputs(sealed, role: :parameter)

    assert fact_id == fact.id and hash == fact_hash(fact)

    # THE SEAM: the version that fired is the version the snapshot names, with
    # the content hash of the published definition the evaluation recorded.
    assert %Definition{version: "1", content_hash: dmn_hash} =
             PlanSnapshot.definition(sealed, :dmn, @key)

    assert dmn_hash == published.content_hash
    assert evaluation.definition_id == published.id
    assert evaluation.definition_version == 1

    # the mzn model rides the same snapshot, so the digest covers parameter,
    # policy and model together
    assert %Definition{content_hash: model_hash} =
             PlanSnapshot.definition(sealed, :mzn, "battery_buffered_day")

    assert model_hash == sha(@model)

    # ── 4. the solve ran over that snapshot and proposed a candidate ─────
    assert plan.solved.status == :feasible and plan.solved.complete?
    assert plan.candidate.checker_ok? in [nil, true]

    %{data: %{assignments: assignments}} = plan.candidate
    assert :ok = Intervals.validate(%{}, assignments)

    [first, second] = assignments
    assert second.start - first.end == plan.buffer

    # the candidate row is a proposal bound to its run, and carries no decision
    # of its own: which version fired is read from the run's sealed snapshot
    assert %CandidateRow{run_id: run_id, disposition: :proposed, check_status: :correct} =
             plan.row

    assert run_id == plan.run_id
    assert PlanSnapshot.digest(sealed) =~ ~r/\A[0-9a-f]{64}\z/

    # nothing but ids and hashes crossed: the snapshot holds no patient text,
    # no atom text, no assignments
    encoded = AshOpenLineage.Snapshot.CanonicalJSON.encode!(sealed)
    refute encoded =~ "Coverage limit"
    refute encoded =~ "task-a"
  end

  test "the judged value picks the DMN row: a different fact gives a different parameter and digest" do
    publish!(1)

    supported = admitted_fact!("supports")
    insufficient = admitted_fact!("insufficient")

    a = plan!(supported)
    b = plan!(insufficient)

    assert {a.buffer, b.buffer} == {15, 45}
    assert a.result.matched_rule_ids == ["rule_supports"]
    assert b.result.matched_rule_ids == ["rule_insufficient"]

    # each candidate honours ITS parameter
    for %{candidate: c, buffer: buffer} <- [a, b] do
      [first, second] = c.data.assignments
      assert second.start - first.end == buffer
    end

    refute PlanSnapshot.digest(a.snapshot) == PlanSnapshot.digest(b.snapshot)

    # same decision version in both: only the judged input moved the digest
    assert PlanSnapshot.definition(a.snapshot, :dmn, @key) ==
             PlanSnapshot.definition(b.snapshot, :dmn, @key)
  end

  test "publishing version 2 of the decision changes the parameter with no code change; v1 still replays" do
    v1 = publish!(1)
    fact = admitted_fact!("supports")

    before = plan!(fact)
    assert {before.buffer, before.result.definition_version} == {15, 1}

    v2 = publish!(2)
    assert v2.version == 2 and v2.content_hash != v1.content_hash

    later = plan!(fact)
    assert {later.buffer, later.result.definition_version} == {10, 2}

    # the fact did not move: the digest differs because the decision did
    assert PlanSnapshot.inputs(before.snapshot) == PlanSnapshot.inputs(later.snapshot)
    refute PlanSnapshot.digest(before.snapshot) == PlanSnapshot.digest(later.snapshot)

    assert %Definition{version: "2", content_hash: hash2} =
             PlanSnapshot.definition(later.snapshot, :dmn, @key)

    assert hash2 == v2.content_hash

    [first, second] = later.candidate.data.assignments
    assert second.start - first.end == 10

    # the earlier candidate's snapshot still verifies and still names v1: a
    # published definition cannot change, so the earlier run replays as it ran
    assert PlanSnapshot.verify(before.snapshot)

    assert %Definition{version: "1", content_hash: hash1} =
             PlanSnapshot.definition(before.snapshot, :dmn, @key)

    assert hash1 == v1.content_hash
    assert Battery.Decisions.Definition.by_key_version!(@key, 1).content_hash == hash1

    # and the evaluation records are one per run, each naming its own version
    versions =
      Evaluation
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.read!()
      |> Enum.map(& &1.definition_version)

    assert versions == [1, 2]
  end

  test "a fact the judge never produced leaves the parameter unresolved, and nothing is solved" do
    publish!(1)

    # no fact: the decision matches no row and refuses (ADR 0041), rather than
    # guessing a buffer
    assert {:error, _reason} = evaluate(nil)

    {:ok, eff, _} = DateTime.from_iso8601("2026-11-09T08:00:00.000000Z")

    sealed =
      %Snapshot{
        id: Ecto.UUID.generate(),
        purpose: :"planning.battery",
        effective_at: eff,
        knowledge_cutoff: eff,
        world: :operational,
        authority: %{tenant: "t-battery", actor_id: "usr-battery", completeness: :full},
        inputs: [parameter_input(nil)],
        definitions: [],
        payload_hash: sha("none")
      }
      |> PlanSnapshot.seal()

    # the snapshot is honest about the gap: it verifies, and is not complete
    assert PlanSnapshot.verify(sealed)
    refute PlanSnapshot.complete?(sealed)

    assert [%Input{key: "fact.evidence_support", status: :unresolved, source: nil}] =
             PlanSnapshot.unresolved_inputs(sealed)

    # the pipeline stops at needs-input: no run, no candidate
    assert Ash.read!(CandidateRow) == []
  end
end
