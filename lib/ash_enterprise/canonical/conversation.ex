defmodule AshEnterprise.Canonical.Conversation do
  @moduledoc """
  A thread: a Gmail thread, a Slack channel, private channel, group DM or DM,
  or a face-to-face the operator logged (dogfood §11). Messages
  (`AshEnterprise.Canonical.Message`) belong to one. `kind` says which of the
  Slack sorts it is.

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
    # Who takes part, as first-class joins: derived from the participants the
    # projector resolved, in the same transaction (ConversationParticipant).
    # Before the seal, which consumes the `participants` argument.
    change AshEnterprise.Canonical.Changes.DeriveParticipants, on: [:create, :update]

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
      [...]}` — the emails (or Slack ids) the source system carried, plus the
      person ids resolved so far. Sealed. The resolved people are also derived
      into `AshEnterprise.Canonical.ConversationParticipant` joins (ids only),
      which is what `people` reads.
      """

      default %{}
    end

    attribute :kind, :atom do
      public? true
      constraints one_of: [:public_channel, :private_channel, :group_dm, :dm]

      description """
      What sort of Slack conversation this is: `:public_channel`,
      `:private_channel`, `:group_dm` (a multi-person DM) or `:dm`. Nil for
      conversations from other sources (a Gmail thread, a logged face-to-face).
      Structural, not sealed: it says a DM exists, not with whom.
      """
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
    has_many :messages, AshEnterprise.Canonical.Message do
      public? true
      description "The messages in this thread."
    end

    has_many :participations, AshEnterprise.Canonical.ConversationParticipant do
      public? true
      description "Who takes part, as derived joins (`AshEnterprise.Canonical.Derive`)."
    end

    many_to_many :people, AshEnterprise.Canonical.Person do
      public? true
      through AshEnterprise.Canonical.ConversationParticipant
      join_relationship :participations
      source_attribute_on_join_resource :conversation_id
      destination_attribute_on_join_resource :person_id
      description "The owner's people taking part in this conversation."
    end

    belongs_to :erasure_scope, AshEnterprise.Erasure.Scope do
      allow_nil? false
      public? true
      attribute_public? true
      attribute_writable? true

      description "The scope of the source this conversation was projected from; its key seals the content."
    end
  end

  aggregates do
    count :message_count, :messages do
      public? true
      description "How many messages the thread holds."
    end

    max :last_message_at, :messages, :sent_at do
      public? true
      description "When the thread's newest message was sent."
    end
  end

  calculations do
    calculate :last_activity, :string, AshEnterprise.Canonical.Calculations.LastActivity do
      public? true
      description "When the newest message was sent, on the operator's wall clock."
    end

    calculate :kind_label, :string, AshEnterprise.Canonical.Calculations.ConversationKind do
      public? true

      description "Channel, Private channel, Group DM, DM — or Thread / Conversation when the source does not say."
    end

    calculate :latest_message,
              :string,
              AshEnterprise.Canonical.Calculations.LatestMessage do
      public? true
      description "The newest message in one line: sender and the start of the body."
    end
  end

  identities do
    # Nullable columns: Postgres leaves multiple NULLs distinct, so an
    # operator-logged conversation (no external identity) never collides.
    identity :unique_external, [:external_system, :external_id]
  end

  actions do
    defaults [:read]

    # One read per message vertical, newest activity first: the Inbox and Slack
    # surfaces (and the ACP `inbox` / `slack` prompts) list these. Empty until
    # the vertical's zone gate admits content (`AshEnterprise.Canonical.Admission`).
    read :gmail do
      description "Gmail threads, newest activity first."
      filter expr(external_system == "gmail")
      prepare build(sort: [last_message_at: :desc_nils_last])
    end

    read :slack do
      description "Slack conversations, newest activity first."
      filter expr(external_system == "slack")
      prepare build(sort: [last_message_at: :desc_nils_last])
    end

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
        :kind,
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
      upsert_fields [:encrypted_subject, :encrypted_participants, :kind, :erasure_scope_id]
    end
  end

  code_interface do
    define :by_external, args: [:system, :id], not_found_error?: false
    define :upsert_from_source
    define :read
  end
end
