defmodule AshEnterprise.Mdm.QualityProjector do
  @moduledoc """
  The MDM finding projector (MDM-7): folds `mdm_reviewed` events into
  compliance findings over the `mdm_quality_findings_v1` grain.

  The bundle is the MDM rules module DIRECTLY — never the organization's
  compliance bundle, whose fact schema is KYC's. A tenant without an active
  MDM program still projects: the rules are code, and the catalog rows are
  the only seeded part.
  """

  use AshCompliance.Projector,
    name: "mdm_quality_findings_v1",
    event_log: AshEnterprise.Compliance.EventLog,
    projection_resource: AshCompliance.Resources.Finding,
    bundle: {__MODULE__, :active_bundle, []}

  grain(fn event ->
    metadata = event.metadata || %{}

    %{
      organization_id: metadata["organization_id"],
      control_id: metadata["control_id"],
      subject_type: metadata["subject_type"],
      subject_id: metadata["subject_id"]
    }
  end)

  project_all([:mdm_reviewed])

  @doc "The MDM rules bundle, IR-round-tripped like every seeded bundle — no org lookup."
  def active_bundle(_event) do
    AshRules.Ir.decode(AshRules.Ir.encode!(AshEnterprise.Mdm.QualityRules.__bundle__()))
  end
end
