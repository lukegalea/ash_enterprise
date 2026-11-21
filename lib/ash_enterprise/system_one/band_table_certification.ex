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

  ## Whether a published table is certified, asked from another tenant

  A certification is recorded in the certifying person's own tenant, and the
  table it certifies is a platform baseline that every tenant bands through.
  A tenant whose suite runs report a family's judged scores
  (`AshEnterprise.Quality.Gate`) therefore asks about a row it cannot read.
  `:for_definition` is that question, and nothing more:

    * **What it matches.** One band-table definition, by its key, version and
      content hash (the published definition's `content_hash`, which the
      certification copied), so a certification of another version, or of
      other content under the same version, never answers for it.
    * **Across tenants.** `multitenancy :bypass`: the rows are in whichever
      tenant the certifier works in.
    * **What it exposes.** `status`, `certified_at` and what the row certifies
      (`definition_key`, `definition_version`, `content_hash`, `family`).
      Every other field, who certified among them, comes back as
      `%Ash.ForbiddenField{}` (`StatusOnly`), whatever the caller selects.
    * **Who may run it.** A person, or a system actor (never `ai`), by its own
      policy, which reads only the actor and queries nothing. The certifier's
      tenant is never named and none of its other rows are read.
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

    read :for_definition do
      description """
      The certifications of one band-table definition, in every tenant: their status and
      when they were made, and nothing about who made them.
      """

      argument :definition_key, :string, allow_nil?: false
      argument :definition_version, :string, allow_nil?: false
      argument :content_hash, :string, allow_nil?: false

      multitenancy :bypass

      filter expr(
               definition_key == ^arg(:definition_key) and
                 definition_version == ^arg(:definition_version) and
                 content_hash == ^arg(:content_hash)
             )

      prepare AshEnterprise.SystemOne.BandTableCertification.StatusOnly
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
    # The fragment's :revoke accepts `certified_by`; a revocation is the approving
    # person's, so it records them, whatever the input says (ADR 0061).
    change AshEnterprise.SystemOne.Changes.RecordApprover, on: [:update]
  end

  # Revoking withdraws the table the family bands through (ADR 0057, 0061).
  # `revoke` is a governed target a Judgment certifier confirms; `revoke_now` and
  # `request_revocation` only invoke it.
  effects do
    action :revoke,
      kind: :execute,
      open_world?: false,
      approval: :confirm,
      approver_role: :judgment_certifier,
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

    policy action([:read, :certified]) do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end

    # Whether a published table is certified is asked from every tenant that bands
    # through it; the answer is status and time only (see the moduledoc).
    policy action(:for_definition) do
      authorize_if AshEnterprise.SystemOne.Checks.PersonActor
      authorize_if AshEnterprise.Security.Checks.SystemActor
    end
  end
end
