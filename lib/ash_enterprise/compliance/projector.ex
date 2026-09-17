defmodule AshEnterprise.Compliance.Projector do
  @moduledoc """
  The KYC finding projector.

  Consumes `AshEnterprise.Compliance.EventLog`, resolves the tenant's active
  `AshCompliance.Resources.PolicyBundle` off the event's `organization_id`,
  and funnels every `kyc_reviewed` event through
  `AshCompliance.Projector.translate/3` — which evaluates with `AshRules` and
  turns the result into finding ops plus an append-only
  `ComplianceEvaluation`.

  The grain is the compliance finding grain:
  `[organization_id, control_id, subject_type, subject_id]`. Subjects are
  projected users; controls are the KYC gaps `KycRules` files under.
  """

  use AshCompliance.Projector,
    name: "kyc_findings_v1",
    event_log: AshEnterprise.Compliance.EventLog,
    projection_resource: AshCompliance.Resources.Finding,
    bundle: {AshEnterprise.Compliance.Projector, :active_bundle, []}

  grain(fn event ->
    metadata = event.metadata || %{}

    %{
      organization_id: metadata["organization_id"],
      control_id: metadata["control_id"],
      subject_type: metadata["subject_type"],
      subject_id: metadata["subject_id"]
    }
  end)

  project_all([:kyc_reviewed])

  @doc """
  Resolves the tenant's active bundle off the event. The most recent
  `:active` bundle for the organization wins; a tenant with no active bundle
  produces an error finding — loud, because a subject evaluated against no
  rules is not a compliant subject.

  Trusted machinery: the projector resolves per event, inside the projection
  transaction, with no user request attached — `authorize?: false` is the
  documented bypass of the package's own interface, not a policy opinion.
  """
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
