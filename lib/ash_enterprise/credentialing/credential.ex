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

    * `kind: :edit`, not destructive, and idempotent: activating the same credential
      twice gives the same registry reference;
    * `open_world?: true`: the registry is outside this application, so the act cannot
      share a transaction with its invocation's completion;
    * `approval: :four_eyes` by the credentialing committee, a member other than the
      requester, valid for three days;
    * `reconcile_with: :lookup_activation`, the read that asks the registry whether an
      activation it may have accepted happened.

  Request it through `AshEnterprise.Execution.invoke/4` with the target
  `"AshEnterprise.Credentialing.Credential.activate_credential"` and the arguments
  `%{"id" => credential_id}`. The domain defines no code interface for it.
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
      idempotent?: true,
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

    update :activate_credential do
      description "Activate the credential with the registry, and record the registry's reference."
      accept []
      # The registry is called before the update's transaction opens, which needs the record.
      require_atomic? false
      change AshEnterprise.Credentialing.Changes.ActivateInRegistry
    end

    action :lookup_activation, :map do
      description "Ask the registry whether it activated the credential."
      argument :credential_id, :uuid, allow_nil?: false
      run AshEnterprise.Credentialing.Actions.LookupActivation
    end
  end
end
