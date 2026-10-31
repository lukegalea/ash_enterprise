defmodule AshEnterprise.SystemOne.BandTableCertification do
  @moduledoc """
  The judgment-side half of band-table certification (RFC v0 §8.2; AST-92
  host wiring): which band-table definition is fit for which question
  family, on what calibration evidence, certified by whom.

  `AshJudgments.Banding.CertificationFragment` supplies the record; the
  platform base supplies the audit and tenancy. Revocation is a new row
  with `status: :revoked` — certifications are superseded, never edited.
  Activation itself stays `ash_decisions`' lifecycle; this record is the
  judgment-side provenance the RFC's §8.2 chain hangs from
  (certification → calibration run → evaluation-set hash).
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.SystemOne,
    ownership: :none,
    lifecycle?: false,
    archival?: false,
    policies?: false,
    extra_extensions: [AshAgent.Effects],
    fragments: [AshJudgments.Banding.CertificationFragment]

  postgres do
    table "system_one_band_table_certifications"
    repo AshEnterprise.Repo
  end

  events do
    create_timestamp :certified_at
  end

  # The certifications surface's contract (AshJudgments.A2ui.Certifications, ADR 0061).
  actions do
    read :certified do
      description "Certifications in force."
      filter expr(status == :certified)
    end

    # What the certifications surface's button runs (ADR 0061): the person's own
    # request to revoke, confirmed by the same person in the same click.
    action :revoke_now, :map do
      description "Revoke the certification, as the person clicking."
      argument :record_id, :uuid, allow_nil?: false

      run {AshEnterprise.Execution.Actions.ConfirmInvocation,
           target: :revoke, key: "revoke", argument: :id}
    end

    # What an agent calls: a request for `revoke`, waiting on a person.
    action :request_revocation, :map do
      description """
      Ask for a certification to be revoked. Nothing changes until a person who may approve
      it does; it then runs as the requesting person.
      """

      argument :record_id, :uuid, allow_nil?: false, public?: true

      run {AshEnterprise.Execution.Actions.RequestInvocation,
           target: :revoke, key: "revoke", key_argument: :record_id, rename: %{record_id: "id"}}
    end
  end

  validations do
    # Revoking is a governed target (ADR 0055): it runs only as its invocation.
    validate {AshAgent.Validations.Governed, invocation: AshEnterprise.Execution.Invocation},
      on: :update,
      where: action_is(:revoke)
  end

  changes do
    # The fragment's :revoke accepts `certified_by`; a revocation is the
    # revoking person's, so it records them, whatever the input says.
    change set_attribute(:certified_by, actor(:email)), on: [:update]
  end

  # Revoking withdraws the table the family bands through (ADR 0057, 0061).
  # `revoke` is a governed target an administrator confirms; `revoke_now` and
  # `request_revocation` only invoke it.
  effects do
    action :revoke,
      kind: :execute,
      open_world?: false,
      approval: :confirm,
      approver_role: :administrator,
      intent: :approve

    action :revoke_now, kind: :execute, open_world?: false, approval: :confirm, intent: :approve

    action :request_revocation,
      kind: :edit,
      destructive?: false,
      open_world?: false,
      intent: :propose
  end

  policies do
    # Certifying is a person's professional act (the author of record is
    # an input); revoking likewise. System machinery neither certifies nor
    # revokes.
    policy action_type([:create, :update]) do
      authorize_if AshEnterprise.SystemOne.Checks.PersonActor
    end

    policy action([:revoke_now, :request_revocation]) do
      authorize_if AshEnterprise.SystemOne.Checks.PersonActor
    end

    policy action_type(:read) do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end
  end
end
