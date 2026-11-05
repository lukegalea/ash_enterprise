defmodule AshEnterprise.Credentialing.Clinic do
  @moduledoc """
  A clinic: the organization a clinician works for.

  Adopted from the CDM `Account` (`mix cdm.gen.resource Account`), keeping only `name`
  of its 165 attributes. User-owned, as Dataverse owns accounts; the person who
  registers a clinic owns it.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Credentialing,
    ownership: :user_owned,
    cdm_entity: "Account"

  postgres do
    table "credentialing_clinics"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 160
      description "The clinic's name."
    end
  end

  relationships do
    has_many :clinicians, AshEnterprise.Credentialing.Clinician do
      public? true
    end
  end

  actions do
    defaults [:read]

    create :register do
      description "Register a clinic, owned by the person registering it."
      accept [:name]
      change set_attribute(:owner_id, actor(:id))
      change set_attribute(:owner_type, :user)
      change set_attribute(:owning_user_id, actor(:id))
      change set_attribute(:owning_business_unit_id, actor(:owning_business_unit_id))
    end
  end
end
