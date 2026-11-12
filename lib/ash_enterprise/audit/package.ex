defmodule AshEnterprise.Audit.Package do
  @moduledoc """
  The audit package: what an auditor is handed for one tenant and one period, as data.

  `export` returns the documents `AshEnterprise.Audit.Package.Build` assembles: the
  criteria in scope and the control file's row for each, the evidence collected with
  each criterion's freshness at the end of the period, the findings open during it,
  the review tasks and their outcomes, the audit chain's verification, and the same
  content as an OSCAL assessment-results document (`AshEnterprise.Audit.Package.Oscal`).
  `mix ash_enterprise.audit.export` writes them to a directory.

  ## The auditor privilege

  Exporting is its own privilege: `read` on this resource (`prvReadPackage`), derived
  into the catalogue like every other privilege and grantable at `:global` only (the
  resource has no rows and no owner). The policy is the platform's inherited grant
  union, unchanged: `RoleGrant` answers a generic action from the precomputed
  `ActorContext`, and only a `:global` grant passes it. A person without the grant is
  refused before anything is read.

  Passing the policy authorizes the reads the build makes, without a second policy
  evaluation, and their reach is fixed in code and reviewed there: the actor's own
  tenant (any other is refused), and in it the compliance plane's rows for that
  organization, the audit chain and the review tasks. It is not a read grant on any
  of those resources. The same shape as `AshEnterprise.Mdm.Egress`.

  ## What it never says

  No criterion is reported as satisfied. `ash_compliance` answers owned, evidenced or
  unknown, and the package carries those answers; an attestation is an auditor's. A
  broken audit chain is reported as broken, whatever else the package holds.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Audit,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false

  # Generic actions only and no rows, but the platform's system attributes are still
  # fields, which trips Ash's primary-key check (as on `AshEnterprise.Mdm.Egress`).
  resource do
    require_primary_key? false
  end

  actions do
    action :export, :map do
      description """
      The audit package for the actor's own tenant over `[from, to)`: criteria,
      evidence with freshness, findings, review tasks and outcomes, the audit
      chain's verification, and an OSCAL assessment-results document.
      """

      argument :from, :utc_datetime_usec do
        allow_nil? false
        description "The start of the period, included."
      end

      argument :to, :utc_datetime_usec do
        allow_nil? false
        description "The end of the period, excluded."
      end

      run AshEnterprise.Audit.Package.Build
    end
  end
end
