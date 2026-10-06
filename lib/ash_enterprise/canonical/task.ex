defmodule AshEnterprise.Canonical.Task do
  @moduledoc """
  A commitment with a status (dogfood §11): captured by the operator or
  extracted from a message by a later epic. `source` records where it came
  from — provenance is mandatory, not decoration.

  Projection-derived, so `archival?`/`lifecycle?` are opted out for the same
  reasons as `AshEnterprise.Canonical.Person`: replay reconstructs, soft delete
  would ghost the upsert identity, and `status` below is this resource's own
  lifecycle — a Dataverse Active/Inactive pair beside it would be two answers
  to one question.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Canonical,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false

  postgres do
    table "canonical_tasks"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints max_length: 1024
      description "What is to be done."
    end

    attribute :due_at, :utc_datetime_usec do
      public? true
      description "When it is due, if it is."
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:open, :done, :cancelled]
      default :open
      description "The commitment's state: open until it is done or cancelled."
    end

    attribute :source, :string do
      allow_nil? false
      public? true
      constraints max_length: 64
      description "Where the task came from: manual, gmail, slack, calendar."
    end

    attribute :external_system, :string do
      public? true
      constraints max_length: 64
      description "Source-of pair: which external system the task was projected from."
    end

    attribute :external_id, :string do
      public? true
      constraints max_length: 512
      description "Source-of pair: that system's id for the task."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_external, [:external_system, :external_id]
  end

  actions do
    defaults [:read]

    read :by_external do
      description """
      Look up the canonical row projected from one raw SourceObject.

      KNOWN GAP (E1 review, fix owned by a dedicated E1 follow-up):
      SourceObject identity is `[external_system, external_id]` *without* the
      stream, and this lookup inherits that shape — two streams sharing an
      external id would land on one row here. Projectors disambiguate by
      filtering `source_metadata["stream"]` when they select their raw rows;
      until the identity is fixed, lookups cannot.
      """

      get? true
      argument :system, :string, allow_nil?: false
      argument :id, :string, allow_nil?: false

      filter expr(external_system == ^arg(:system) and external_id == ^arg(:id))
    end

    create :upsert_from_source do
      description "The replay write path: upsert on the source identity."

      accept [
        :title,
        :due_at,
        :status,
        :source,
        :external_system,
        :external_id,
        :owner_id,
        :owner_type,
        :owning_user_id,
        :owning_business_unit_id
      ]

      upsert? true
      upsert_identity :unique_external
      upsert_fields [:title, :due_at, :status, :source]
    end
  end

  code_interface do
    define :by_external, args: [:system, :id], not_found_error?: false
    define :upsert_from_source
    define :read
  end
end
