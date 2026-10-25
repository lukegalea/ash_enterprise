defmodule Battery.Integration.LedgerProjectionComplianceTest do
  @moduledoc """
  Scenario 3 — ledger → projection → compliance finding.

  The flow: a vendor-review business event is committed to the BIZEV
  ledger; the ledger's projector folds it into the VendorState projection
  (drained with the package-owned per-region drain); the compliance
  projector translates the review event into a FINDING by evaluating the
  ACTIVE policy bundle — compiled from an ash_rules rule set serialized
  through the compliance plane — with facts read off the BIZEV projection.

  The integration property: the finding tracks the PROJECTED state (flip
  the ledger and the finding resolves), and pins the bundle hash it was
  evaluated against.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias AshCompliance.Resources.{ComplianceEvaluation, RuleSetRevision}
  alias AshCompliance.Testing
  alias Battery.BusinessEvents.{Ledger, Projector, VendorState}

  @reviewed_at ~U[2026-10-01T09:00:00.000000Z]
  @corrected_at ~U[2026-10-02T09:00:00.000000Z]

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Battery.Repo, sandbox: false)

    # The ledger's immutability trigger forbids DELETE; TRUNCATE is the
    # sanctioned, conspicuous reset.
    Battery.Repo.query!("TRUNCATE ledger_events, ledger_simulation_events")

    for table <-
          ~w(mapping_versions battery_vendor_states
             bizev_projection_checkpoints bizev_projection_dead_letter_events
             bizev_projection_registry battery_compliance_event_log battery_event_log
             ash_compliance_rule_set_revisions ash_compliance_policy_bundles
             ash_compliance_findings ash_compliance_compliance_evaluations
             ash_compliance_tenant_policy_sets) do
      Battery.Repo.query!("DELETE FROM " <> table)
    end

    :ok
  end

  test "a projected vendor state drives a compliance finding from the active bundle" do
    org = Ecto.UUID.generate()
    vendor_ref = unique_ref()

    # ── 1. the business event lands in the ledger ─────────────────────────
    Ledger.record!(%{
      event_kind: :"vendor_review.completed",
      region: :us,
      residency_tag: "us",
      subject_type: "vendor",
      subject_external_id: vendor_ref,
      subject_stream: :vendor,
      occurred_at: @reviewed_at,
      data: %{"review_status" => "rejected", "reviewer" => "Dana Ops"},
      provenance: %{
        "mapping_name" => "manual_vendor_review",
        "mapping_version_hash" => "manual",
        "source_record_id" => nil
      }
    })

    # ── 2. the ledger projector folds it into the projection ──────────────
    assert Projector.drain(:us) == 1

    [state] = vendor_states(vendor_ref)
    assert state.review_status == "rejected"
    assert state.subject == vendor_ref
    assert state.region == :us

    # ── 3. the compliance plane: rules → revision → ACTIVE bundle ─────────
    activate_vendor_bundle(org)

    # ── 4. the compliance projector projects the finding ──────────────────
    :ok =
      Testing.drain_sync(Battery.Compliance.Projector, [
        review_event(org, vendor_ref, 1, @reviewed_at)
      ])

    [finding] = AshCompliance.Domain.list_findings!(authorize?: false)

    assert finding.status == :noncompliant
    assert finding.control_id == "vendor.approved_required"
    # the fired rule's gap IS the finding's control id — the projector
    # files requirements under their gap reference
    assert finding.subject_type == "vendor"
    assert finding.subject_id == vendor_ref
    assert finding.organization_id == org
    assert finding.severity == :high
    assert finding.breach_count == 1
    assert finding.rule_ids == ["vendor.approved_required"]

    # every finding pins the bundle that produced it — the audit trail
    assert finding.bundle_hash == active_bundle_hash(org)

    # the decision is on the record too
    [evaluation] = AshCompliance.Domain.list_evaluations!(authorize?: false)

    assert evaluation.outcome == :noncompliant
    assert evaluation.bundle_hash == finding.bundle_hash
    assert evaluation.subject_id == vendor_ref
    assert evaluation.correlation_id == "corr-1"

    # ── 5. THE SEAM: correcting the LEDGER (not the finding) resolves it ──
    correction =
      Ledger.record!(%{
        event_kind: :"vendor_review.completed",
        region: :us,
        residency_tag: "us",
        subject_type: "vendor",
        subject_external_id: vendor_ref,
        subject_stream: :vendor,
        occurred_at: @corrected_at,
        supersedes_event_id: nil,
        data: %{"review_status" => "approved", "reviewer" => "Dana Ops"},
        provenance: %{
          "mapping_name" => "manual_vendor_review",
          "mapping_version_hash" => "manual",
          "source_record_id" => nil
        }
      })

    assert Projector.drain(:us) == 1

    [state] = vendor_states(vendor_ref)
    assert state.review_status == "approved"

    :ok =
      Testing.drain_sync(Battery.Compliance.Projector, [
        review_event(org, vendor_ref, 2, @corrected_at)
      ])

    [finding] = AshCompliance.Domain.list_findings!(authorize?: false)

    assert finding.status == :compliant
    assert finding.resolved_at != nil
    assert finding.breach_count == 1

    # the correction is a NEW ledger row — the original was never rewritten
    assert %Ledger{} = correction

    last_evaluation =
      ComplianceEvaluation
      |> Ash.Query.sort(evaluated_at: :asc)
      |> Ash.read!()
      |> List.last()

    assert last_evaluation.outcome == :compliant
  end

  test "unknown review state never becomes compliant" do
    org = Ecto.UUID.generate()
    vendor_ref = unique_ref()

    # A vendor with NO projected state: the fact extraction fails honestly
    # (unknown is not compliant), so the finding lands :error, not :compliant.
    activate_vendor_bundle(org)

    :ok =
      Testing.drain_sync(Battery.Compliance.Projector, [
        review_event(org, vendor_ref, 1, @reviewed_at)
      ])

    [finding] = AshCompliance.Domain.list_findings!(authorize?: false)

    assert finding.status == :error
    assert finding.explanation =~ "no projected vendor state"
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp unique_ref, do: "V-" <> Integer.to_string(System.unique_integer([:positive]))

  defp vendor_states(ref) do
    VendorState
    |> Ash.Query.filter(subject == ^ref)
    |> Ash.read!()
  end

  defp review_event(org, vendor_ref, id, occurred_at) do
    Testing.event(
      id: id,
      action: :vendor_review_completed,
      occurred_at: occurred_at,
      metadata: %{
        "organization_id" => org,
        "control_id" => "vendor.approved_required",
        "subject_type" => "vendor",
        "subject_id" => vendor_ref,
        "region" => :us,
        "correlation_id" => "corr-#{id}"
      }
    )
  end

  defp activate_vendor_bundle(org) do
    bundle = Battery.Compliance.VendorRules.__bundle__()

    _revision =
      RuleSetRevision
      |> Ash.Changeset.for_create(
        :draft,
        %{
          organization_id: org,
          name: "vendor-rules-1",
          revision: "1",
          layer: :global_mandatory,
          combining: :deny_overrides,
          rules_json: AshRules.Ir.encode!(bundle),
          content_hash: bundle.content_hash
        },
        authorize?: false
      )
      |> Ash.create!()
      |> Ash.update!(%{}, action: :validate, authorize?: false)
      |> Ash.update!(%{}, action: :approve, authorize?: false)
      |> Ash.update!(%{}, action: :activate, authorize?: false)

    {:ok, compiled} =
      AshCompliance.Domain.compile_policy_bundle(
        %{organization_id: org, label: "battery vendor baseline"},
        authorize?: false
      )

    {:ok, active} = AshCompliance.Domain.activate_policy_bundle(compiled, authorize?: false)
    active
  end

  defp active_bundle_hash(org) do
    {:ok, bundle} = AshCompliance.Domain.active_policy_bundle(org, authorize?: false)
    bundle.content_hash
  end
end
