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

    # The governed target (ADR 0055): it runs only as its invocation, after a
    # person approved the request.
    action :certify_and_publish, :map do
      description """
      Certify the run's proposed band table as the person, and publish it. Run only by
      its invocation (`certify:<run id>`); ask for it with `request_certification`.
      """

      argument :record_id, :uuid, allow_nil?: false
      validate {AshAgent.Validations.Governed, invocation: AshEnterprise.Execution.Invocation}
      run AshEnterprise.SystemOne.BandTablePublication.CertifyAndPublish
    end

    # What the band-table surface's button runs (ADR 0061): the person's own
    # request, confirmed by the same person in the same click.
    action :certify_now, :map do
      description "Certify the run's proposed band table and publish it, as the person clicking."
      argument :record_id, :uuid, allow_nil?: false

      run {AshEnterprise.Execution.Actions.ConfirmInvocation,
           target: :certify_and_publish, key: "certify", argument: :record_id}
    end

    # What an agent calls: a request for `certify_and_publish`, waiting on a person.
    action :request_certification, :map do
      description """
      Ask for the run's proposed band table to be certified and published. Nothing changes
      until a person who may approve it does; it then runs as the requesting person.
      """

      argument :record_id, :uuid, allow_nil?: false, public?: true

      run {AshEnterprise.Execution.Actions.RequestInvocation,
           target: :certify_and_publish, key: "certify", key_argument: :record_id}
    end
  end

  # Certifying publishes the table that bands the family live from then on
  # (ADR 0041, 0057, 0061). `certify_and_publish` is a governed target: an
  # administrator confirms it ("Administrator" is the role that may certify
  # band tables; there is no narrower one). `certify_now` and
  # `request_certification` only invoke it.
  effects do
    action :certify_and_publish,
      kind: :execute,
      open_world?: false,
      approval: :confirm,
      approver_role: :administrator,
      preconditions: [:record_id],
      intent: :approve

    action :certify_now,
      kind: :execute,
      open_world?: false,
      approval: :confirm,
      intent: :approve

    action :request_certification,
      kind: :edit,
      destructive?: false,
      open_world?: false,
      intent: :propose
  end

  policies do
    # Certifying is a person's act (ADR 0041, 0059). It comes before the
    # bypass, which covers only the policies after it.
    policy action([:certify_and_publish, :certify_now, :request_certification]) do
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
