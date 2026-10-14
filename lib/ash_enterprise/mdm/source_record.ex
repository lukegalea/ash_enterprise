defmodule AshEnterprise.Mdm.SourceRecord do
  @moduledoc """
  The bizev temporal raw-landing layer instantiated for MDM ingress.

  `tenant?: false` is deliberate and load-bearing: bizev's identity is
  `(source, stream, external_id, region)` and the Land path knows nothing
  of organizations — mounting organization_id on the row would leave it
  nil (NOT NULL failure) or, worse, let two tenants sharing an external_id
  collide into one temporal record. Tenancy is IN the external_id
  (`"org:slug:row_key"`, see `AshEnterprise.Mdm.Landing`), so cross-tenant
  collision is structurally impossible rather than policy-disciplined.

  `audit?: false`: the temporal record IS the provenance (content, region,
  residency tag, period) — a central-log row per landed observation would
  double the write volume for a fact the row itself already answers.

  KNOWN EXPOSURE (found in the ADR 0050 build, fix owed by a platform-security
  slice): reads are governed by the grant union, but this row carries no
  `organization_id`, so every scope clause that would narrow a grant is nil
  here — a GLOBAL role grant reads every tenant's raw landed rows, and the
  only fence for non-global grants is the `"org:slug:key"` external_id
  convention. The convention is load-bearing but structurally unenforced.
  The minimal fix is a RoleGrant clause for attribute-less resources that
  filters `external_id` by the actor's organization prefix; it belongs in
  the security slice because it changes every `tenant?: false` resource at
  once.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Mdm,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    policies?: false

  use AshDiscreteBusinessEvents.Resources, :source_record

  postgres do
    table "mdm_source_records"
    repo AshEnterprise.Repo
  end

  policies do
    # `policies?: false` with an explicit set, as on Mapping: the raw layer
    # is organization-scoped by convention inside external_id, so reads
    # follow the platform grant union; the engine bypasses first.
    bypass AshBpmn.Checks.AshBpmnInteraction do
      authorize_if always()
    end

    bypass AshDecisions.Checks.AshDecisionsInteraction do
      authorize_if always()
    end

    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    policy always() do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
      authorize_if AshEnterprise.Security.Checks.SharedWithActor
      authorize_if AshEnterprise.Security.Checks.HierarchyGrant
    end
  end
end
