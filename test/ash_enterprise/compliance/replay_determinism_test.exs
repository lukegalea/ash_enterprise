defmodule AshEnterprise.Compliance.ReplayDeterminismTest do
  @moduledoc """
  Replay determinism is the acceptance bar for the compliance data plane
  (`docs/plans/ash-rules-and-compliance.md`, §Testing): the same bundle plus
  the same event range must produce identical findings and identical
  evaluations, byte for byte, every time.

  The second half of this file pins what a RULE CHANGE does to a replay,
  which is the v2 story from the rule census: activating
  `AshEnterprise.Compliance.KycRulesV2` (revision "2", one severity moved)
  and re-draining the *same* events changes exactly the finding the change
  was about — severity — and nothing else. If a rule change silently
  reshuffles unrelated findings, the audit trail is lying about why any of
  them exist.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshCompliance.Resources.{ComplianceEvaluation, Finding, PolicyBundle, RuleSetRevision}
  alias AshCompliance.Testing
  alias AshEnterprise.Compliance.{EventLog, Projector}

  setup do
    # Repeating an evaluation is the evaluator's own contract; recording one
    # is not. Every review below runs as the tenant's seeded compliance
    # administrator, because the event log's create is governed like every
    # other append in this application.
    seeded = AshEnterprise.Platform.Seeder.seed_legacy_estate()

    org = seeded.organization.id

    officer =
      AshEnterprise.Security.ActorContext.attach(
        seeded.user,
        AshEnterprise.Security.ActorContext.build(seeded.user, tenant: org)
      )

    {:ok, bundle} = AshEnterprise.Compliance.Seeds.seed(org)

    %{org: org, bundle: bundle, officer: officer}
  end

  test "the same events replay into byte-identical findings and evaluations", %{
    org: org,
    officer: officer
  } do
    AshEnterprise.Compliance.Kyc.record_review(org, "replay-1", review_facts(), actor: officer)

    events = events_since_marker(0)
    :ok = Testing.drain_sync(Projector, Enum.map(events, &normalize_event/1))

    first_findings = finding_snapshot(org)
    first_evaluations = evaluation_snapshot(org)

    assert first_findings != %{}
    assert first_evaluations != %{}

    # Replay: wipe the projection and the audit record, fold the SAME event
    # rows through the SAME projector again. Neither resource carries a
    # destroy action — the projection is engine-written, the evaluation
    # append-only — so the wipe is raw SQL, exactly what the engine's own
    # rebuild path does behind its truncate. `Ecto.UUID.dump!` because the
    # org id arrives as a string and Postgrex wants raw bytes.
    org_bytes = Ecto.UUID.dump!(org)

    AshEnterprise.Repo.query!(
      "DELETE FROM ash_compliance_findings WHERE organization_id = $1",
      [org_bytes]
    )

    AshEnterprise.Repo.query!(
      "DELETE FROM ash_compliance_compliance_evaluations WHERE organization_id = $1",
      [org_bytes]
    )

    :ok = Testing.drain_sync(Projector, Enum.map(events, &normalize_event/1))

    assert finding_snapshot(org) == first_findings
    assert evaluation_snapshot(org) == first_evaluations
  end

  test "repeated evaluation of the same inputs is deterministic", %{org: org} do
    bundle = decoded_bundle(org)

    results =
      for _n <- 1..25 do
        {:ok, result} = AshRules.evaluate(bundle, evaluate_facts(bundle))
        result
      end

    # The determinism contract is structural: rules in id order, facts in
    # sorted order, bindings de-duplicated. Assert the whole result — not
    # samples of it — matches across every run.
    first = hd(results)

    assert Enum.all?(results, fn result ->
             result.requirements == first.requirements and
               result.derived_facts == first.derived_facts and
               result.missing_facts == first.missing_facts and
               result.overall == first.overall
           end)
  end

  test "activating revision 2 changes exactly the finding the change was about", %{
    org: org,
    officer: officer
  } do
    AshEnterprise.Compliance.Kyc.record_review(org, "change-1", review_facts(), actor: officer)
    events = events_since_marker(0)
    :ok = Testing.drain_sync(Projector, Enum.map(events, &normalize_event/1))

    before = finding_snapshot(org)
    assert before["kyc.migration"].severity == :low

    # The lifecycle is the control plane's own: validate → approve → activate,
    # and the outgoing revision retires. Revision 2 was seeded as a draft.
    v2 =
      RuleSetRevision
      |> Ash.Query.filter(organization_id == ^org and name == "kyc-baseline" and revision == "2")
      |> Ash.read_one!(authorize?: false)

    v1 =
      RuleSetRevision
      |> Ash.Query.filter(organization_id == ^org and name == "kyc-baseline" and revision == "1")
      |> Ash.read_one!(authorize?: false)

    v2 =
      v2
      |> Ash.Changeset.for_update(:validate, %{}, authorize?: false)
      |> Ash.update!(authorize?: false)
      |> Ash.Changeset.for_update(:approve, %{}, authorize?: false)
      |> Ash.update!(authorize?: false)
      |> Ash.Changeset.for_update(:activate, %{}, authorize?: false)
      |> Ash.update!(authorize?: false)

    _activated_v2 = v2

    v1
    |> Ash.Changeset.for_update(:retire, %{}, authorize?: false)
    |> Ash.update!(authorize?: false)

    # Compile AND activate: an unactivated bundle is invisible to the
    # projector, which is the lifecycle working, not a bug to work around.
    previous = active_bundle(org)

    {:ok, new_bundle} = Ash.create(PolicyBundle, %{organization_id: org}, action: :compile)

    new_bundle =
      new_bundle
      |> Ash.Changeset.for_update(:activate, %{}, authorize?: false)
      |> Ash.update!(authorize?: false)

    previous
    |> Ash.Changeset.for_update(:retire, %{}, authorize?: false)
    |> Ash.update!(authorize?: false)

    # Re-drain the SAME events under the NEW bundle.
    :ok = Testing.drain_sync(Projector, Enum.map(events, &normalize_event/1))

    after_v2 = finding_snapshot(org)

    # The one rule the revision patched: severity low → high.
    assert after_v2["kyc.migration"].severity == :high
    # Statuses are untouched — the change was severity, not behaviour.
    assert after_v2["kyc.migration"].status == before["kyc.migration"].status

    # Every OTHER control reads identically: same status, same explanation.
    # Findings re-evaluated under the new bundle re-set their timestamps from
    # the event, so even `last_seen_at` agrees — but the bundle hash records
    # which rule set produced each evaluation, and that must differ.
    for control <- Map.keys(before), control != "kyc.migration" do
      assert after_v2[control].status == before[control].status,
             "control #{control} changed status under a severity-only patch"

      assert after_v2[control].explanation == before[control].explanation,
             "control #{control} changed explanation under a severity-only patch"
    end

    active = new_bundle
    assert active.content_hash != before["kyc.migration"].bundle_hash
    assert after_v2["kyc.migration"].bundle_hash == active.content_hash

    # The evaluation log kept both truths, append-only.
    eval_hashes =
      ComplianceEvaluation
      |> Ash.Query.filter(organization_id == ^org)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.bundle_hash)
      |> Enum.uniq()

    assert length(eval_hashes) == 2
  end

  # --- helpers ------------------------------------------------------------------

  defp review_facts do
    [
      ["customer", "status", "active"],
      ["customer", "jurisdiction", "unknown"],
      ["customer", "email_domain", "example.org"],
      ["customer", "risk_tier", "high"],
      ["customer", "open_remedications", 1],
      ["acct-1", "account_owner", "customer"],
      ["acct-1", "account_balance", 250]
    ]
  end

  # Facts for the direct-evaluation determinism check: a mix of present,
  # absent-with-:unknown-semantics and absent-with-:no_fact-semantics facts,
  # plus the variable join, so every evaluator path is exercised per run.
  defp evaluate_facts(bundle) do
    names =
      bundle.fact_schema.facts
      |> Enum.map(& &1.name)
      |> Enum.sort()

    values = %{
      status: :active,
      jurisdiction: :regulated,
      risk_tier: :high,
      email_domain: "example.org",
      account_owner: :customer,
      account_balance: 250
    }

    for name <- names, value = Map.get(values, name) do
      {"customer", name, value}
    end
  end

  defp decoded_bundle(org) do
    {:ok, decoded} = AshRules.Ir.decode(active_bundle(org).rules_json)
    decoded
  end

  defp active_bundle(org) do
    PolicyBundle
    |> Ash.Query.filter(organization_id == ^org and status == :active)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end

  defp events_since_marker(marker) do
    EventLog
    |> Ash.Query.filter(id > ^marker)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp normalize_event(event) do
    %{
      id: event.id,
      practice_id: event.practice_id,
      user_id: event.user_id,
      occurred_at: event.occurred_at,
      metadata: event.metadata,
      resource: event.resource,
      action: event.action,
      action_type: event.action_type
    }
  end

  defp finding_snapshot(org) do
    Finding
    |> Ash.Query.filter(organization_id == ^org)
    |> Ash.read!(authorize?: false)
    |> Map.new(fn finding ->
      {finding.control_id,
       %{
         status: finding.status,
         severity: finding.severity,
         breach_count: finding.breach_count,
         explanation: finding.explanation,
         rule_ids: finding.rule_ids,
         bundle_hash: finding.bundle_hash,
         first_seen_at: finding.first_seen_at,
         last_seen_at: finding.last_seen_at,
         resolved_at: finding.resolved_at
       }}
    end)
  end

  defp evaluation_snapshot(org) do
    ComplianceEvaluation
    |> Ash.Query.filter(organization_id == ^org)
    |> Ash.read!(authorize?: false)
    # Sorted by the SOURCE EVENT, not the row's random uuid: a replayed
    # evaluation is a new row with a new id, and sorting on it would order
    # the replay differently from the original run for reasons that have
    # nothing to do with determinism.
    |> Enum.sort_by(&(&1.source_event_id && String.to_integer(&1.source_event_id)))
    |> Enum.map(fn evaluation ->
      %{
        control_id: evaluation.control_id,
        subject_id: evaluation.subject_id,
        outcome: evaluation.outcome,
        bundle_hash: evaluation.bundle_hash,
        bundle_revision: evaluation.bundle_revision,
        fact_snapshot_hash: evaluation.fact_snapshot_hash,
        missing_facts: evaluation.missing_facts,
        rule_ids: evaluation.rule_ids,
        correlation_id: evaluation.correlation_id,
        evaluated_at: evaluation.evaluated_at
      }
    end)
  end
end
