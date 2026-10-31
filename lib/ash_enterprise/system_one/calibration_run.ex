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
    extra_extensions: [AshAgent.Effects],
    fragments: [AshJudgments.Calibration.Fragment]

  postgres do
    table "system_one_calibration_runs"
    repo AshEnterprise.Repo
  end

  events do
    create_timestamp :started_at
  end

  # The band-table surface's contract (AshJudgments.A2ui.BandTables, ADR 0061).
  actions do
    read :awaiting_certification do
      description "Runs that proposed a band table no one has certified yet."

      filter expr(
               result == :proposed_table and
                 not exists(
                   AshEnterprise.SystemOne.BandTableCertification,
                   calibration_run_id == parent(id)
                 )
             )

      prepare build(sort: [finished_at: :asc])
    end

    action :certify_and_publish, :map do
      description "A person certifies the run's proposed band table, and it is published."
      argument :record_id, :uuid, allow_nil?: false
      run AshEnterprise.SystemOne.BandTablePublication.CertifyAndPublish
    end
  end

  # Certifying publishes the table that bands the family live from then on (ADR 0041, 0057). The person confirms by clicking; an agent's request for it is
  # S1-78's governed path.
  effects do
    action :certify_and_publish,
      kind: :execute,
      open_world?: false,
      approval: :confirm,
      intent: :approve
  end

  policies do
    # Certifying is a person's act (ADR 0041, 0059). It comes before the
    # bypass, which covers only the policies after it.
    policy action(:certify_and_publish) do
      authorize_if AshEnterprise.SystemOne.Checks.PersonActor
    end

    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end
  end
end
