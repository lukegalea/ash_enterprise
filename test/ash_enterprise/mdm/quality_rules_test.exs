defmodule AshEnterprise.Mdm.QualityRulesTest do
  @moduledoc """
  The MDM-7 vertical slice: a golden's quality review emits one event per
  control, the projector folds them into findings, and the MDM program never
  touches the organization's compliance bundle (KYC's fact schema must not
  mix with MDM's).
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshCompliance.Resources.Finding
  alias AshCompliance.Testing
  alias AshEnterprise.Compliance.EventLog
  alias AshEnterprise.Mdm.{QualityProjector, QualityReview, QualityRules}
  alias AshEnterprise.Platform.Seeder

  setup do
    %{organization: organization, user: admin} =
      Seeder.seed_tenant(
        name: "Quality #{System.unique_integer([:positive])}",
        unique_name: "quality-#{System.unique_integer([:positive])}"
      )

    org = organization.id
    :ok = QualityReview.seed_quality_catalog(org)

    %{org: org, admin: admin}
  end

  defp golden!(org, admin, name, email) do
    AshEnterprise.Canonical.Person
    |> Ash.Changeset.for_create(:upsert_from_source, %{
      name: name,
      email: email,
      owner_id: admin.id,
      owning_business_unit_id: admin.owning_business_unit_id
    })
    |> Ash.create!(tenant: org, authorize?: false)
  end

  defp review_and_project!(org, admin, golden) do
    marker = marker()

    officer =
      AshEnterprise.Security.ActorContext.attach(
        admin,
        AshEnterprise.Security.ActorContext.build(admin, tenant: org)
      )

    :ok = QualityReview.review_golden(org, golden, actor: officer)

    events =
      EventLog
      |> Ash.Query.filter(
        id > ^marker and action == ^:mdm_reviewed and
          metadata["subject_id"] == ^to_string(golden.id)
      )
      |> Ash.Query.sort(id: :asc)
      |> Ash.read!(authorize?: false)

    :ok =
      Testing.drain_sync(
        QualityProjector,
        Enum.map(events, fn event ->
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
        end)
      )

    :ok
  end

  defp marker do
    case EventLog |> Ash.Query.sort(id: :desc) |> Ash.read_one!(authorize?: false) do
      nil -> 0
      event -> event.id
    end
  end

  defp findings_for(org, golden_id) do
    Finding
    |> Ash.Query.filter(
      organization_id == ^org and subject_type == "person" and subject_id == ^golden_id
    )
    |> Ash.read!(authorize?: false)
  end

  test "a complete golden files no findings", %{org: org, admin: admin} do
    golden = golden!(org, admin, "Complete Kathy", "kathy@x.io")

    # A golden is golden because an identity feeds it: provenance open.
    AshEnterprise.Mdm.SourceIdentity
    |> Ash.Changeset.for_create(
      :open,
      %{
        source: "manual_csv",
        stream: "upload",
        external_id: "#{org}:acme:kathy",
        golden_resource: "AshEnterprise.Canonical.Person",
        golden_id: golden.id,
        asserted_by: :steward
      },
      tenant: org,
      authorize?: false
    )
    |> Ash.create!(tenant: org, authorize?: false)

    review_and_project!(org, admin, golden)

    # The projector files a finding per control; a clean golden's findings
    # are all :compliant.
    findings = findings_for(org, golden.id)

    assert findings != []
    assert Enum.all?(findings, &(&1.status == :compliant))
  end

  test "a golden without an email files a contact finding", %{org: org, admin: admin} do
    golden = golden!(org, admin, "Blind Bobby", nil)
    review_and_project!(org, admin, golden)

    findings = findings_for(org, golden.id)

    assert Enum.any?(
             findings,
             &(&1.control_id == "mdm.contact" and &1.status == :noncompliant)
           )
  end

  test "the MDM program never enters the organization's compliance bundle", %{org: org} do
    {:ok, bundle} = AshCompliance.Domain.active_policy_bundle(org, authorize?: false)

    # No active compliance bundle was created for this tenant by the MDM
    # program; and even with one (KYC), its rules carry no mdm gap.
    case bundle do
      nil ->
        assert true

      bundle ->
        {:ok, decoded} = AshRules.Ir.decode(bundle.rules_json)

        refute Enum.any?(decoded.rules, fn rule ->
                 rule.outcome && String.starts_with?(to_string(rule.outcome.gap || ""), "mdm.")
               end)
    end
  end
end
