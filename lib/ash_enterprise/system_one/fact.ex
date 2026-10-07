defmodule AshEnterprise.SystemOne.Fact do
  @moduledoc """
  The materialised-facts table (RFC v0 §7.4; S1-53 host wiring): what the
  set evaluator, the filters and the standing queries read. Admitted
  facts land here through `AshJudgments.Facts.Materialiser` — the sole
  intended caller, which the host's banding step routes to.

  `AshJudgments.Facts.TemporalFragment` supplies the set-evaluator
  contract (subject/predicate/value), the §7.4 columns and the freshness
  calculations — with **record validity carried as a period** (the facts
  temporal-swap, design note §2; AST-149 host cut-over): a revision is a
  period split at the admission's `effective_at`, an omission truncates
  the period (history preserved, the predicate returns to unknown), and
  the `WITHOUT OVERLAPS` identity on
  `(subject_type, subject_id, predicate, scope_hash)` enforces one open
  period per subject+predicate+scope at any instant. Supersession
  bookkeeping (`superseded_by`, `:supersede`, `current?`, the `:current`
  filter) is deleted: a plain read IS the as-of-now read (`strategy
  :context`). `valid_until` remains the SECOND axis — domain validity (a
  licence expires on a date), deliberately not the period. The platform
  base supplies the audit and tenancy; the table is AshEvents-audited, so
  the as_of capture/replay harness works over its events and the §5.2
  migration replays the legacy table's recorded writes. Facts are never
  edited — a revision is a new period, enforced by the database. Writes
  are machinery (the materialiser runs as a system actor), reads are
  role-gated.
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
    fragments: [AshJudgments.Facts.TemporalFragment]

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
