defmodule AshEnterprise.Canonical.Project do
  @moduledoc """
  A named container for work (dogfood §11): the thing tasks and events are
  *about*. Minimal by contract — a name and, for projected rows, the source
  pair.

  Organization-owned: a project is the workspace's container, not the
  operator's personal row. Projection-derived, so `archival?`/`lifecycle?` are
  opted out for the same reasons as `AshEnterprise.Canonical.Person`: replay
  reconstructs, soft delete would ghost the upsert identity, the lifecycle pair
  carries no meaning.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Canonical,
    ownership: :organization_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false

  postgres do
    table "canonical_projects"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 256
      description "The project's name."
    end

    attribute :external_system, :string do
      public? true
      constraints max_length: 64
      description "Source-of pair: which external system the project was projected from."
    end

    attribute :external_id, :string do
      public? true
      constraints max_length: 512
      description "Source-of pair: that system's id for the project."
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
      accept [:name, :external_system, :external_id]

      upsert? true
      upsert_identity :unique_external
      upsert_fields [:name]
    end
  end

  code_interface do
    define :by_external, args: [:system, :id], not_found_error?: false
    define :upsert_from_source
    define :read
  end
end
