defmodule AshEnterprise.Test.Execution.ClinicianFile do
  @moduledoc """
  A test-only record an agent run can be about: one clinician's file at a clinic,
  sealed under that clinician's own erasure scope (`data_subject`), so that a test can
  play the clinician asking to be erased.

  Like `AshEnterprise.Test.Execution.ClinicNote`, it is a view of `canonical_tasks`
  (`migrate? false`, in a domain that is never registered), so the tests add no schema.
  `open` and `read` are self-service: a member opens a file as its owner and reads only
  the files they own.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Test.Execution,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false,
    lineage?: false,
    self_service: [:open, :read]

  postgres do
    table "canonical_tasks"
    repo AshEnterprise.Repo
    migrate? false
  end

  actions do
    defaults [:read]

    create :open do
      accept [:title, :erasure_scope_id]
      change set_attribute(:owner_id, actor(:id))
      change set_attribute(:source, "clinician_file")
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :source, :string, allow_nil?: false, public?: true

    attribute :erasure_scope_id, :uuid do
      allow_nil? false
      public? true
      description "The clinician's own erasure scope."
    end

    update_timestamp :updated_at
  end
end
