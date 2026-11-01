defmodule AshEnterprise.Credentialing.Credential do
  @moduledoc """
  A clinician's licence or certification, recorded at the clinic and activated with the
  registry before the clinician may practise there.

  Invented rather than adopted: the vendored CDM corpus models customers, activities
  and service, and has no entity for a professional qualification. This resource is
  the clinic scenario's own noun and holds only what the scenario uses. `status` is its
  lifecycle (`pending`, then `active`), so the Dataverse Active/Inactive pair is left
  off (`lifecycle?: false`).

  ## Activation is governed

  `activate_credential` reaches the registry (`AshEnterprise.Credentialing.Registry`),
  so its effects declaration says so:

    * `kind: :edit`, not destructive, and not idempotent: the registry takes no
      idempotency key, and each activation it accepts is an entry of its own;
    * `open_world?: true`: the registry is outside this application, so the act cannot
      share a transaction with its invocation's completion;
    * `approval: :four_eyes` by the credentialing committee, a member other than the
      requester, valid for three days;
    * `reconcile_with: :lookup_activation`, the read that asks the registry whether an
      activation it may have accepted happened. So an activation whose answer was lost
      (the worker died after the registry accepted it, failure scenario F2) becomes
      `outcome_unknown` and is settled by asking, never by activating again.

  Request it with `request_activation` (the credentialing workspace's button), or through
  `AshEnterprise.Execution.invoke/4` with the target
  `"AshEnterprise.Credentialing.Credential.activate_credential"` and the arguments
  `%{"id" => credential_id}`. The action itself has no code interface, and refuses to run
  except by its own invocation (`AshAgent.Validations.Governed`).

  ## Evidence checks

  `check_documents` and `check_expiry` are the checks a credentialing process runs side by
  side, as service tasks through their invocations
  (`AshEnterprise.Process.ActionInvoker`'s `check_licence_documents` and
  `check_licence_expiry`). Each refuses with a business error a diagram's error boundary
  catches (`AshEnterprise.Credentialing.Actions.CheckEvidence`).

  `correct` changes the credential's number or expiry date. A correction while an
  activation waits for approval moves the credential's version on, so the approval no
  longer holds (failure scenario F4).
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Credentialing,
    ownership: :user_owned,
    lifecycle?: false,
    extra_extensions: [AshAgent.Effects]

  postgres do
    table "credentialing_credentials"
    repo AshEnterprise.Repo
  end

  effects do
    action :activate_credential,
      kind: :edit,
      read_only?: false,
      destructive?: false,
      idempotent?: false,
      open_world?: true,
      approval: :four_eyes,
      approver_role: :credentialing_committee,
      approval_expires_in: [days: 3],
      intent: :execute,
      reconcile_with: :lookup_activation

    action :lookup_activation,
      kind: :fetch,
      destructive?: false,
      idempotent?: true,
      open_world?: true,
      intent: :inspect

    action :request_activation,
      kind: :edit,
      destructive?: false,
      open_world?: false,
      intent: :propose

    action :correct,
      kind: :edit,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :execute

    action :check_documents,
      kind: :read,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect

    action :check_expiry,
      kind: :read,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect
  end

  attributes do
    uuid_primary_key :id

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:licence, :certification]
    end

    attribute :number, :string do
      allow_nil? false
      public? true
      sensitive? true
      constraints max_length: 64
      description "The number the issuing body gave the credential."
    end

    attribute :expires_on, :date do
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: [:pending, :active]
    end

    attribute :registry_reference, :string do
      public? true
      constraints max_length: 128
      description "The registry's reference for the activation."
    end

    attribute :activated_at, :utc_datetime_usec do
      public? true
    end
  end

  relationships do
    belongs_to :clinician, AshEnterprise.Credentialing.Clinician do
      allow_nil? false
      public? true
    end

    has_many :licence_documents, AshEnterprise.Credentialing.LicenceDocument do
      public? true
    end
  end

  calculations do
    calculate :document_findings,
              :string,
              AshEnterprise.Credentialing.Calculations.DocumentFindings do
      public? true

      description "What the licence reader found in the credential's documents, and the lines it cites."
    end
  end

  actions do
    defaults [:read]

    create :record do
      description "Record a clinician's credential, pending activation."
      accept [:kind, :number, :expires_on, :clinician_id]
      change set_attribute(:owner_id, actor(:id))
      change set_attribute(:owner_type, :user)
      change set_attribute(:owning_user_id, actor(:id))
      change set_attribute(:owning_business_unit_id, actor(:owning_business_unit_id))
    end

    update :correct do
      description "Correct the credential's number or expiry date."
      accept [:number, :expires_on]
    end

    action :request_activation, :map do
      description """
      Ask for the credential to be activated with the registry. Nothing changes until a
      member of the credentialing committee other than you approves it: the result is the
      request, with its status and the link where it waits for approval.
      """

      argument :record_id, :uuid, allow_nil?: false, public?: true

      run {AshEnterprise.Execution.Actions.RequestInvocation,
           target: :activate_credential, rename: %{record_id: "id"}}
    end

    update :activate_credential do
      description "Activate the credential with the registry, and record the registry's reference."
      accept []
      # The registry is called before the update's transaction opens, which needs the record.
      require_atomic? false
      validate {AshAgent.Validations.Governed, invocation: AshEnterprise.Execution.Invocation}
      change AshEnterprise.Credentialing.Changes.ActivateInRegistry
    end

    action :lookup_activation, :map do
      description "Ask the registry whether it activated the credential."
      argument :id, :uuid, allow_nil?: false
      run AshEnterprise.Credentialing.Actions.LookupActivation
    end

    action :check_documents, :map do
      description """
      Check that a licence document is filed for the credential. Refuses with
      `licence_document_missing` when none is.
      """

      argument :id, :uuid, allow_nil?: false
      run {AshEnterprise.Credentialing.Actions.CheckEvidence, check: :documents}
    end

    action :check_expiry, :map do
      description """
      Check that the credential states an expiry date that has not passed. Refuses with
      `expiry_date_missing` or `credential_expired`.
      """

      argument :id, :uuid, allow_nil?: false
      run {AshEnterprise.Credentialing.Actions.CheckEvidence, check: :expiry}
    end
  end
end
