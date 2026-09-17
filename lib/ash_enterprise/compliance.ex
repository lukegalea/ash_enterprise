defmodule AshEnterprise.Compliance do
  @moduledoc """
  The compliance domain: the `ash_compliance` control plane and data plane,
  surfaced into this application.

  ## What lives here

  * `AshEnterprise.Compliance.EventLog` — the compliance event log the
    projector drains. Deliberately **not** `AshEnterprise.Audit.EventLog`:
    the audit trail's schema is owned by the tamper-evident chain (ADR 0002),
    and the projector engine's drain selects its wake-up columns by name. The
    central trail still records every platform write; this log carries the
    compliance fact payload a KYC evaluation consumes.
  * `AshEnterprise.Compliance.KycRules` — the KYC rule set (`use AshRules`),
    compiled to revisions through `AshEnterprise.Compliance.Seeds`.
  * `AshEnterprise.Compliance.Projector` — the finding projector.

  The `ash_compliance` resources themselves (catalogs, profiles, bundles,
  findings, evaluations, evidence) are listed in this domain unchanged: they
  resolve `AshEnterprise.Repo` through application env and are administered
  through the admin A2UI surfaces. See ADR 0033.

  The three `ash_events_projections` engine resources (checkpoint, dead
  letter, registry) are listed here too — not for access, but so their
  tables belong to this application's migration set, the same way the
  `ash_bpmn` resources live in `AshEnterprise.Bpmn`: the engine resolves
  repo and table prefix through application env, and codegen can only see
  resources a host domain declares.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshCompliance.Resources.Catalog
    resource AshCompliance.Resources.CatalogVersion
    resource AshCompliance.Resources.Control
    resource AshCompliance.Resources.ControlRevision
    resource AshCompliance.Resources.Profile
    resource AshCompliance.Resources.ProfileRevision
    resource AshCompliance.Resources.RuleSetRevision
    resource AshCompliance.Resources.PolicyBundle
    resource AshCompliance.Resources.TenantPolicySet
    resource AshCompliance.Resources.PolicyOverride
    resource AshCompliance.Resources.ControlMapping
    resource AshCompliance.Resources.Finding
    resource AshCompliance.Resources.ComplianceEvaluation
    resource AshCompliance.Resources.EvidenceArtifact

    resource AshEnterprise.Compliance.EventLog

    # The projector engine's own bookkeeping. Listed for codegen and for the
    # DLQ/verify operations tasks; nothing outside the engine reads them.
    resource AshEvents.Projections.Checkpoint
    resource AshEvents.Projections.DeadLetter
    resource AshEvents.Projections.Registry
  end
end
