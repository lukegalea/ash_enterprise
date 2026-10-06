defmodule AshEnterprise.Canonical.Conversation do
  @moduledoc """
  A thread: a Gmail thread, a Slack channel or DM thread, or a face-to-face the
  operator logged (dogfood §11). Messages (`AshEnterprise.Canonical.Message`)
  belong to one.

  PERSONAL DATA (ADR 0042): the Gmail/Slack verticals must not enable their
  projectors until zone admission gates the SourceObject land path. See the
  TODO on `AshEnterprise.Canonical.Projection`.

  Projection-derived, so `archival?`/`lifecycle?` are opted out for the same
  reasons as `AshEnterprise.Canonical.Person`: replay reconstructs, soft delete
  would ghost the upsert identity, the lifecycle pair carries no meaning.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Canonical,
    ownership: :organization_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false

  postgres do
    table "canonical_conversations"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :subject, :string do
      public? true
      constraints max_length: 998
      description "The thread's subject line or channel-joined title."
    end

    attribute :participants, :map do
      public? true

      description """
      Who is in the thread, keyed by role: `%{"emails" => [...], "person_ids" =>
      [...]}`. A map rather than a join table for v1 — linkage is email-based
      (no entity resolution, roadmap P4), so the honest shape is the emails the
      source system carried, plus person ids resolved so far.
      """

      default %{}
    end

    attribute :external_system, :string do
      public? true
      constraints max_length: 64
      description "Source-of pair: which external system the conversation was projected from."
    end

    attribute :external_id, :string do
      public? true
      constraints max_length: 512
      description "Source-of pair: that system's id for the conversation (thread id, channel id)."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    # Nullable columns: Postgres leaves multiple NULLs distinct, so an
    # operator-logged conversation (no external identity) never collides.
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
      accept [:subject, :participants, :external_system, :external_id]

      upsert? true
      upsert_identity :unique_external
      upsert_fields [:subject, :participants]
    end
  end

  code_interface do
    define :by_external, args: [:system, :id], not_found_error?: false
    define :upsert_from_source
    define :read
  end
end
