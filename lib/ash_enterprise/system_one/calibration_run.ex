defmodule AshEnterprise.SystemOne.CalibrationRun do
  @moduledoc """
  The calibration-run record (RFC v0 §8.1; AST-91 host wiring): one row
  per `(family, question hashes, model digest, runtime version, eval-set
  hash, region)` — sample sizes, the metrics object as decimal strings,
  the conformal thresholds at the family's target risk, the provenance,
  and the RECORDED band-table proposal.

  `AshJudgments.Calibration.Fragment` supplies the record (everything an
  input; the only derived field is the pure `record_hash` — law 2); the
  platform base supplies the audit and tenancy. Negative results are kept
  (`:no_table`, `:regression` — ADR 0047 point 7). Recording runs through
  `AshEnterprise.SystemOne.Calibration.record_run/2`, which runs the
  n-threshold trigger BEFORE the create: a run below the family's minimum
  proposes nothing and is recorded as `:no_table`. The review queue
  surfaces `:proposed_table` runs that have no certification yet.

  Policies follow the banding ledger's posture: recording runs is
  machinery (the calibration harness, a system actor); reads are
  role-gated.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.SystemOne,
    ownership: :none,
    lifecycle?: false,
    archival?: false,
    policies?: false,
    fragments: [AshJudgments.Calibration.Fragment]

  postgres do
    table "system_one_calibration_runs"
    repo AshEnterprise.Repo
  end

  events do
    create_timestamp :started_at
  end

  policies do
    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end
  end
end
