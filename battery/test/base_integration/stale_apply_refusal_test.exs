defmodule Battery.Integration.StaleApplyRefusalTest do
  @moduledoc """
  Scenario — planning: a candidate whose snapshot inputs drift after approval
  is refused at apply, and ends rejected and stale.

  The cross-substrate seam, mirroring ash_enterprise's `candidate_apply_test`
  drift case: a plan is read from three substrates and pinned into an
  `AshOpenLineage` snapshot as ids, versions and hashes —

    * a demand row with an optimistic lock (`Battery.Execution.Referral`),
      pinned by `(resource, id, version_number)`;
    * a judged fact (System One), with no version number, pinned by id and
      content hash;
    * a published decision (ash_decisions), pinned by key, version and
      content hash.

  A person approves the candidate. Before apply, one of the three moves. Apply
  re-reads every source against the snapshot: a row that moved, vanished or
  was republished is DRIFT, nothing is written to the operational ledger, and
  the candidate is settled `:stale` then `:rejected` (the order the fragment's
  guards force: `mark_stale` is refused once a candidate is decided, `reject`
  is allowed from `:approved`). A refused candidate never reads as an
  approved one, and cannot be applied afterwards. An unmoved snapshot applies,
  as the control.

  The candidate's lifecycle is the package's `AshPlanning.Fragment.Candidate`
  (its guards run for real); the recheck and the write are the host's, here
  the battery's. Synthetic ids and slots only; only ids and hashes cross.
  """

  use ExUnit.Case, async: false

  import Battery.PlanningKit

  alias AshJudgments.Registry.Info
  alias AshOpenLineage.Snapshot
  alias AshOpenLineage.Snapshot.{Definition, Input}
  alias AshPlanning.Snapshot, as: PlanSnapshot
  alias Battery.BusinessEvents.Ledger
  alias Battery.Decisions.Evaluation
  alias Battery.Execution.Referral
  alias Battery.SystemOne.{CaseFile, Fact}

  @key "battery_apply_policy"
  @model "var 0..96: slot_a; var 0..96: slot_b; constraint slot_a != slot_b;"

  # A trivial synthetic policy so the plan pins a decision: two versions, a
  # different output each. UNIQUE, one unconditional row.
  defp policy_dmn(version) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <definitions xmlns="https://www.omg.org/spec/DMN/20230324/MODEL/"
                 xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                 id="#{@key}_definitions"
                 name="#{@key}"
                 namespace="https://battery.test/#{@key}"
                 expressionLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/"
                 typeLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/">
      <inputData id="input_urgent" name="urgent">
        <variable id="var_urgent" name="urgent" typeRef="boolean"/>
      </inputData>
      <decision id="decision_#{@key}" name="#{@key}">
        <variable id="var_#{@key}" name="#{@key}" typeRef="string"/>
        <informationRequirement id="req_urgent">
          <requiredInput href="#input_urgent"/>
        </informationRequirement>
        <decisionTable id="table_#{@key}" hitPolicy="UNIQUE" outputLabel="window">
          <input id="clause_urgent" label="Urgent">
            <inputExpression id="expr_urgent" typeRef="boolean"><text>urgent</text></inputExpression>
          </input>
          <output id="clause_window" name="window" label="window" typeRef="string"/>
          <rule id="rule_any">
            <inputEntry id="rule_any_0"><text>-</text></inputEntry>
            <outputEntry id="rule_any_1"><text>"policy_v#{version}"</text></outputEntry>
          </rule>
        </decisionTable>
      </decision>
    </definitions>
    """
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Battery.Repo, sandbox: false)

    # The ledger's immutability trigger forbids DELETE; TRUNCATE is the
    # sanctioned reset.
    Battery.Repo.query!("TRUNCATE ledger_events, ledger_simulation_events")
    Enum.each([Fact, Evaluation, Battery.Decisions.Definition], &Battery.Repo.delete_all/1)

    publish!(1)
    approver = %{id: Ecto.UUID.generate()}

    referrals =
      for n <- 1..2 do
        Ash.create!(Referral, %{
          patient: "SYNTHETIC patient #{System.unique_integer([:positive])}-#{n}"
        })
      end

    %{fact: fact, subject: subject} = admit_fact!("supports")

    %{approver: approver, referrals: referrals, fact: fact, subject: subject}
  end

  # ── the sources the plan reads ───────────────────────────────────────────

  defp publish!(version) do
    definition =
      Battery.Decisions.Definition.create!(%{
        key: @key,
        name: "Battery apply policy",
        xml: policy_dmn(version)
      })

    assert definition.graph, "policy v#{version} failed to compile: #{inspect(definition.errors)}"
    {:ok, published} = Battery.Decisions.Definition.publish(definition)
    published
  end

  defp admit_fact!(value, subject \\ nil) do
    question = Info.question(CaseFile, :evidence_support)
    subject = subject || %{"type" => "Battery.SystemOne.CaseFile", "id" => Ecto.UUID.generate()}
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

    [fact] =
      Fact
      |> Ash.Query.for_read(:for_subject, %{subject: subject, predicate: question.question_id})
      |> Ash.read!()

    %{fact: fact, subject: subject}
  end

  defp amend!(referral) do
    referral
    |> Ash.Changeset.for_update(:amend, %{consent_on_file?: true})
    |> Ash.update!()
  end

  defp referral_hash(r) do
    canonical_hash(%{
      "patient_hash" => sha(r.patient),
      "urgent" => r.urgent?,
      "consent_on_file" => r.consent_on_file?,
      "version_number" => r.version_number
    })
  end

  defp fact_hash(f) do
    canonical_hash(%{
      "predicate" => f.predicate,
      "value" => to_string(f.value),
      "subject_state_digest" => f.subject_state_digest
    })
  end

  defp referral_input(r) do
    %Input{
      key: "referral.#{r.id}",
      role: :demand,
      status: :value,
      source: %{
        resource: "Battery.Execution.Referral",
        id: r.id,
        version_number: r.version_number
      },
      content_hash: referral_hash(r)
    }
  end

  defp fact_input(f) do
    %Input{
      key: "fact.evidence_support",
      role: :parameter,
      status: :value,
      source: %{resource: "Battery.SystemOne.Fact", id: f.id, version_number: nil},
      content_hash: fact_hash(f)
    }
  end

  # The snapshot, read from the sources AS THEY ARE NOW.
  defp snapshot!(ctx) do
    {:ok, eff, _} = DateTime.from_iso8601("2026-11-09T08:00:00.000000Z")
    {:ok, definition} = Battery.Bpmn.DecisionResolver.latest_published(@key)

    referrals = Enum.map(ctx.referrals, &Ash.get!(Referral, &1.id))
    [fact] = current_facts(ctx.subject)

    %Snapshot{
      id: Ecto.UUID.generate(),
      purpose: :"planning.battery",
      effective_at: eff,
      knowledge_cutoff: eff,
      world: :operational,
      authority: %{tenant: "t-battery", actor_id: "usr-battery", completeness: :full},
      inputs: Enum.map(referrals, &referral_input/1) ++ [fact_input(fact)],
      definitions: [
        %Definition{
          kind: :dmn,
          key: @key,
          version: Integer.to_string(definition.version),
          content_hash: definition.content_hash
        },
        %Definition{kind: :mzn, key: "battery_slots", version: "1", content_hash: sha(@model)}
      ],
      payload_hash: sha("lowered-problem")
    }
    |> PlanSnapshot.seal()
  end

  defp current_facts(subject) do
    question = Info.question(CaseFile, :evidence_support)

    Fact
    |> Ash.Query.for_read(:for_subject, %{subject: subject, predicate: question.question_id})
    |> Ash.read!()
  end

  # ── the host's half of apply: recheck every source, then write ───────────

  # Every source is read again. A row that is gone, whose version moved or
  # whose content hash differs is drift; a definition republished since is too.
  # Returns the keys that moved.
  defp drift(%Snapshot{} = snapshot) do
    inputs =
      for %Input{status: :value, source: source} = input <- snapshot.inputs,
          source_moved?(source, input.content_hash),
          do: input.key

    definitions =
      for %Definition{kind: :dmn} = d <- snapshot.definitions,
          definition_moved?(d),
          do: "dmn.#{d.key}"

    inputs ++ definitions
  end

  defp source_moved?(%{resource: "Battery.Execution.Referral", id: id, version_number: v}, hash) do
    case Ash.get(Referral, id, not_found_error?: false) do
      {:ok, %Referral{} = row} -> row.version_number != v or referral_hash(row) != hash
      _gone -> true
    end
  end

  defp source_moved?(%{resource: "Battery.SystemOne.Fact", id: id}, hash) do
    case Ash.get(Fact, id, not_found_error?: false) do
      {:ok, %Fact{} = row} -> fact_hash(row) != hash
      _gone -> true
    end
  end

  defp definition_moved?(%Definition{key: key, version: version, content_hash: hash}) do
    case Battery.Bpmn.DecisionResolver.latest_published(key) do
      {:ok, latest} -> Integer.to_string(latest.version) != version or latest.content_hash != hash
      _gone -> true
    end
  end

  # Writes each assignment to the operational ledger: what an applied plan
  # makes true. Nothing else writes there.
  defp write!(assignments) do
    for %{"id" => id, "slot" => slot} <- assignments do
      Ledger.record!(%{
        event_kind: :"referral.scheduled",
        region: :us,
        residency_tag: "us",
        subject_type: "referral",
        subject_external_id: id,
        subject_stream: :referral,
        occurred_at: ~U[2026-11-09 08:00:00.000000Z],
        data: %{"slot" => slot},
        provenance: %{
          "mapping_name" => "planning_apply",
          "mapping_version_hash" => "manual",
          "source_record_id" => nil
        }
      })
    end

    :ok
  end

  # Apply as ash_enterprise does: recheck, then write and settle; drift ends
  # `:stale` first (machinery), `:rejected` second (the person).
  defp apply_candidate(candidate, snapshot, approver) do
    case drift(snapshot) do
      [] ->
        write!(Jason.decode!(candidate.assignments))
        {:ok, transition!(candidate, :apply, %{}, actor: approver)}

      moved ->
        candidate |> transition!(:mark_stale) |> transition!(:reject)
        {:error, {:drift, moved}}
    end
  end

  defp approved_plan!(ctx) do
    snapshot = snapshot!(ctx)
    [a, b] = ctx.referrals
    assignments = [%{"id" => a.id, "slot" => 36}, %{"id" => b.id, "slot" => 38}]

    candidate =
      Ecto.UUID.generate()
      |> propose!(0, assignments)
      |> transition!(:approve)

    assert candidate.disposition == :approved and candidate.check_status == :correct
    %{snapshot: snapshot, candidate: candidate, assignments: assignments}
  end

  defp ledger_rows, do: Ash.read!(Ledger, authorize?: false)

  # A refused apply: stale AND rejected, never approved-looking, written
  # nowhere, and closed to every later move.
  defp assert_refused(candidate, approver) do
    settled = reload!(candidate)
    assert settled.freshness == :stale
    assert settled.disposition == :rejected
    assert is_nil(settled.applied_by_actor_id)
    assert ledger_rows() == []

    assert {:error, _} = transition(settled, :apply, %{}, actor: approver)
    assert {:error, _} = transition(settled, :approve)
    assert reload!(candidate).disposition == :rejected
  end

  test "a referral amended after approval refuses the apply: rejected and stale, nothing written",
       ctx do
    %{snapshot: snapshot, candidate: candidate} = plan = approved_plan!(ctx)
    assert drift(snapshot) == []

    [first, second] = ctx.referrals
    amend!(first)

    assert {:error, {:drift, moved}} = apply_candidate(candidate, snapshot, ctx.approver)
    assert moved == ["referral.#{first.id}"]
    refute "referral.#{second.id}" in moved

    assert_refused(candidate, ctx.approver)

    # the snapshot is a record, not a live view: it still verifies and still
    # names the version the plan was made on...
    assert PlanSnapshot.verify(snapshot)

    assert Enum.any?(
             PlanSnapshot.sources(snapshot),
             &(&1.id == first.id and &1.version_number == first.version_number)
           )

    # ...and replanning over the sources as they are now is a new snapshot,
    # a new digest, and a candidate that applies.
    fresh = snapshot!(ctx)
    refute PlanSnapshot.digest(fresh) == PlanSnapshot.digest(snapshot)
    assert drift(fresh) == []

    replanned = Ecto.UUID.generate() |> propose!(0, plan.assignments) |> transition!(:approve)
    assert {:ok, applied} = apply_candidate(replanned, fresh, ctx.approver)
    assert applied.disposition == :applied
    assert applied.freshness == :current
    assert applied.applied_by_actor_id == ctx.approver.id
    assert length(ledger_rows()) == 2
  end

  test "a judged fact revised after approval is drift by content hash, with no version number to read",
       ctx do
    %{snapshot: snapshot, candidate: candidate} = approved_plan!(ctx)

    assert [%{version_number: nil}] =
             Enum.filter(PlanSnapshot.sources(snapshot), &is_nil(&1.version_number))

    # the judge changes its mind: the same subject and predicate, a new value
    admit_fact!("insufficient", ctx.subject)

    assert {:error, {:drift, ["fact.evidence_support"]}} =
             apply_candidate(candidate, snapshot, ctx.approver)

    assert_refused(candidate, ctx.approver)
  end

  test "a decision republished after approval is drift: the plan ran on a version no longer current",
       ctx do
    %{snapshot: snapshot, candidate: candidate} = approved_plan!(ctx)
    assert %Definition{version: "1"} = PlanSnapshot.definition(snapshot, :dmn, @key)

    publish!(2)

    assert {:error, {:drift, ["dmn." <> @key]}} =
             apply_candidate(candidate, snapshot, ctx.approver)

    assert_refused(candidate, ctx.approver)

    # replanned over the current policy, the plan names v2 and applies
    fresh = snapshot!(ctx)
    assert %Definition{version: "2"} = PlanSnapshot.definition(fresh, :dmn, @key)
  end

  test "a snapshot nothing has moved under applies: the control", ctx do
    %{snapshot: snapshot, candidate: candidate} = approved_plan!(ctx)

    assert {:ok, applied} = apply_candidate(candidate, snapshot, ctx.approver)
    assert applied.disposition == :applied
    assert applied.freshness == :current
    assert applied.applied_by_actor_id == ctx.approver.id

    assert [%{subject_external_id: a}, %{subject_external_id: b}] =
             Enum.sort_by(ledger_rows(), & &1.sequence)

    assert Enum.sort([a, b]) == Enum.sort(Enum.map(ctx.referrals, & &1.id))

    # a candidate is applied once: a second apply is refused by the guards
    assert {:error, _} = transition(reload!(candidate), :apply, %{}, actor: ctx.approver)
  end

  test "drift found before approval keeps the candidate from being approved at all", ctx do
    snapshot = snapshot!(ctx)
    [first, second] = ctx.referrals

    candidate =
      Ecto.UUID.generate()
      |> propose!(0, [%{"id" => first.id, "slot" => 12}, %{"id" => second.id, "slot" => 14}])

    amend!(second)
    assert drift(snapshot) == ["referral.#{second.id}"]

    # the recheck marks it stale while it is still only proposed...
    stale = transition!(candidate, :mark_stale)
    assert stale.freshness == :stale and stale.disposition == :proposed

    # ...and the guards refuse to approve a stale candidate, however correct
    assert {:error, error} = transition(stale, :approve)
    assert Exception.message(error) =~ "stale"
    assert reload!(candidate).disposition == :proposed
    assert ledger_rows() == []
  end
end
