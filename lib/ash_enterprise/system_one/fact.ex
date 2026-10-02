defmodule AshEnterprise.SystemOne.Fact do
  @moduledoc """
  The materialised-facts table (RFC v0 §7.4; S1-53 host wiring): what the
  set evaluator, the filters and the standing queries read. Admitted
  facts land here through `AshJudgments.Facts.Materialiser` — the sole
  intended caller, which the host's banding step routes to.

  `AshJudgments.Facts.Fragment` supplies the set-evaluator contract
  (subject/predicate/value), the §7.4 columns and the freshness
  calculations; the platform base supplies the audit and tenancy. Facts
  are superseded, never edited (`:supersede` is the one sanctioned
  update); writes are machinery (the materialiser runs as a system actor),
  reads are role-gated.
  """

  # Not multitenant, on purpose, at this stage: the package's materialiser
  # (`AshJudgments.Facts.Materialiser`) is tenant-less by contract — tenancy
  # rides in the fact's `scope` data, and the facts lane's own host wiring
  # (S1-53) owns multitenancy. Forcing organization_id on the resource
  # would break the sole sanctioned write path.
  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.SystemOne,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    policies?: false,
    fragments: [AshJudgments.Facts.Fragment]

  postgres do
    table "system_one_facts"
    repo AshEnterprise.Repo
  end

  events do
    create_timestamp :recorded_at
  end

  policies do
    # The materialiser is the sole sanctioned caller of the fragment's
    # machinery actions, and it deliberately passes no actor. One named,
    # greppable bypass — the engine-bypass pattern — declares that
    # authority here rather than an anonymous authorize?: false inside the
    # package. An actor PRESENT on those actions matches nothing here:
    # persons and system actors have no grant path to hand-materialise.
    bypass AshEnterprise.SystemOne.Checks.FactMaterialiser do
      authorize_if always()
    end

    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end
  end
end
