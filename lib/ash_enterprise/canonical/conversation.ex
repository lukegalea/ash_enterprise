defmodule AshEnterprise.Canonical.Conversation do
  @moduledoc """
  A thread: a Gmail thread, a Slack channel or DM thread, or a face-to-face the
  operator logged (dogfood §11). Messages (`AshEnterprise.Canonical.Message`)
  belong to one.

  PERSONAL DATA (ADR 0042). Projected only from landed records a zone gate
  admits (`AshEnterprise.Canonical.Projections.ZoneGate`), and **owner-only**:
  user-owned, and no role can be granted more than `:basic` on it
  (`AshEnterprise.Security.Privilege.owner_only?/1`), so a thread is readable
  by the user it was projected for and nobody else in the tenant.

  Projection-derived, so `archival?`/`lifecycle?` are opted out for the same
  reasons as `AshEnterprise.Canonical.Person`: replay reconstructs, soft delete
  would ghost the upsert identity, the lifecycle pair carries no meaning.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Canonical,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false,
    extra_extensions: [AshCloak]

  postgres do
    table "canonical_conversations"
    repo AshEnterprise.Repo

    references do
      reference :erasure_scope, on_delete: :restrict
    end
  end

  # `subject` and `participants` are content and personal data (participant
  # emails): sealed under the erasure scope of the source this conversation was
  # projected from (ADR 0024; see AshEnterprise.Canonical.Message).
  cloak do
    vault({AshEnterprise.Erasure.Vault, :resolve, []})
    attributes [:subject, :participants]
    decrypt_by_default([:subject, :participants])
    encrypt_nil?(false)
  end

  changes do
    change {AshEnterprise.Erasure.Changes.SealUnderScope, fields: [:subject, :participants]},
      on: [:create, :update]
  end

  attributes do
    uuid_primary_key :id

    attribute :subject, :string do
      public? true
      # No max_length on a sealed attribute: a failed constraint renders the
      # value into the error message (Ash's InvalidArgument), and errors reach
      # traces, Oban and BPMN incidents, which no shred reaches (ADR 0024).
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

  relationships do
    belongs_to :erasure_scope, AshEnterprise.Erasure.Scope do
      allow_nil? false
      public? true
      attribute_public? true
      attribute_writable? true

      description "The scope of the source this conversation was projected from; its key seals the content."
    end
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

      accept [
        :subject,
        :participants,
        :external_system,
        :external_id,
        :erasure_scope_id,
        # The ownership columns are NOT NULL; a projector has no actor to
        # derive them from, so it passes them (as Message's does). INSERT-time
        # only: they are not upsert fields.
        :owner_id,
        :owner_type,
        :owning_user_id,
        :owning_business_unit_id
      ]

      upsert? true
      upsert_identity :unique_external
      upsert_fields [:encrypted_subject, :encrypted_participants, :erasure_scope_id]
    end
  end

  code_interface do
    define :by_external, args: [:system, :id], not_found_error?: false
    define :upsert_from_source
    define :read
  end
end
