defmodule Battery.Compliance.Projector do
  @moduledoc """
  The battery's compliance projector: `AshCompliance.Projector` over the
  battery's event log, projecting findings onto the package's Finding
  grain. The bundle resolves through the ACTIVE PolicyBundle (only bundles
  evaluate); the facts come from the BIZEV projection via
  `Battery.Compliance.Facts`.

  Drained synchronously in the scenarios with `AshCompliance.Testing.drain_sync/3`.
  """

  use AshCompliance.Projector,
    name: "battery_compliance_findings_v1",
    event_log: Battery.Compliance.EventLog,
    projection_resource: AshCompliance.Resources.Finding,
    bundle: {Battery.Compliance.Projector, :active_bundle, []},
    facts: {Battery.Compliance.Facts, :from_event, []}

  grain(fn event ->
    metadata = event.metadata || %{}

    %{
      organization_id: metadata["organization_id"],
      control_id: metadata["control_id"],
      subject_type: metadata["subject_type"],
      subject_id: metadata["subject_id"]
    }
  end)

  project_all([:vendor_review_completed])

  def active_bundle(event) do
    organization_id = event.metadata["organization_id"]

    case AshCompliance.Domain.active_policy_bundle(organization_id, authorize?: false) do
      {:ok, nil} ->
        {:error, :no_active_bundle}

      {:ok, bundle} ->
        AshRules.Ir.decode(bundle.rules_json)

      {:error, error} ->
        {:error, error}
    end
  end
end
