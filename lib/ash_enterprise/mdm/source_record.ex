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

  Raw landings are MACHINERY-visible only (found in the ADR 0053 build): the
  row carries no `organization_id`, so the grant union's scope clauses are
  all nil here and a GLOBAL role grant would read every tenant's raw rows —
  the `"org:slug:key"` external_id convention is a convention, not a fence.
  So the policy set refuses persons outright: the pipeline reads landings
  as the system actor (or unauthorised inside the engine), and the steward's
  surfaces are the tenant-scoped StagedRecord/goldens. Raw payloads are not
  a person-readable surface.
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

    # No person path: a raw landing is not a person-readable surface (the
    # grant union cannot scope a row with no organization_id — a global
    # grant would read every tenant). Machinery reaches landings through
    # the bypasses and `authorize?: false` inside the pipeline.
    policy always() do
      forbid_if always()
    end
  end
end
