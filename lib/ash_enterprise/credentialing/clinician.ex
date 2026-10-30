defmodule AshEnterprise.Credentialing.Clinician do
  @moduledoc """
  A clinician a clinic is onboarding.

  Adopted from the CDM `Contact` (`mix cdm.gen.resource Contact`), keeping
  `first_name`, `last_name` and `job_title` of its 214 attributes. The CDM's
  `parent_customer_id` (an account or a contact) narrows to `clinic_id`. The two names
  are personal data, so they are `sensitive?` and stay out of the audit log.
  User-owned, as Dataverse owns contacts.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Credentialing,
    ownership: :user_owned,
    cdm_entity: "Contact"

  postgres do
    table "credentialing_clinicians"
    repo AshEnterprise.Repo
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
    end
  end
end
