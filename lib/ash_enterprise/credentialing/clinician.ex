defmodule AshEnterprise.Credentialing.Clinician do
  @moduledoc """
  A clinician a clinic is onboarding.

  Adopted from the CDM `Contact` (`mix cdm.gen.resource Contact`), keeping
  `first_name`, `last_name` and `job_title` of its 214 attributes. The CDM's
  `parent_customer_id` (an account or a contact) narrows to `clinic_id`. The two names
  are personal data, so they are `sensitive?` and stay out of the audit log.
  User-owned, as Dataverse owns contacts.

  Each clinician has their own erasure scope (`erasure_scope_id`,
  `AshEnterprise.Credentialing.Changes.OpenClinicianScope`), opened when they are
  registered, or by `open_erasure_scope` for one registered before scopes were. A run
  about the clinician is sealed under it (an agent reading their licence documents), so
  when the clinician asks to be erased, one shred erases every copy the run made.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Credentialing,
    ownership: :user_owned,
    cdm_entity: "Contact"

  postgres do
    table "credentialing_clinicians"
    repo AshEnterprise.Repo

    references do
      reference :erasure_scope, on_delete: :restrict
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :first_name, :string do
      public? true
      sensitive? true
      constraints max_length: 50
    end

    attribute :last_name, :string do
      allow_nil? false
      public? true
      sensitive? true
      constraints max_length: 50
    end

    attribute :job_title, :string do
      public? true
      constraints max_length: 100
      description "What the clinician does at the clinic, such as Physiotherapist."
    end
  end

  relationships do
    belongs_to :clinic, AshEnterprise.Credentialing.Clinic do
      allow_nil? false
      public? true
    end

    has_many :credentials, AshEnterprise.Credentialing.Credential do
      public? true
    end

    belongs_to :erasure_scope, AshEnterprise.Erasure.Scope do
      public? true
      attribute_public? true
      description "The clinician's own scope; its key seals what runs about them copy."
    end
  end

  actions do
    defaults [:read]

    create :register do
      description "Register a clinician at a clinic, owned by the person registering them."
      accept [:first_name, :last_name, :job_title, :clinic_id]
      change set_attribute(:owner_id, actor(:id))
      change set_attribute(:owner_type, :user)
      change set_attribute(:owning_user_id, actor(:id))
      change set_attribute(:owning_business_unit_id, actor(:owning_business_unit_id))
      change AshEnterprise.Credentialing.Changes.OpenClinicianScope
    end

    update :open_erasure_scope do
      description "Give a clinician registered before clinicians had scopes their own."
      accept []
      require_atomic? false
      change AshEnterprise.Credentialing.Changes.OpenClinicianScope
    end
  end
end
