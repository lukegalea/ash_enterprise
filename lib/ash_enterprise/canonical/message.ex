defmodule AshEnterprise.Canonical.Message do
  @moduledoc """
  The §11 email/Slack message row: one sent or received item in a conversation,
  with its sender, timestamp and direction.

  PERSONAL DATA (ADR 0042). The Gmail and Slack projectors
  (`AshEnterprise.Canonical.Projections.Gmail` / `.Slack`) project only what
  their configured zone gate admits; the template default admits nothing, and
  `AshEnterprise.Canonical.Projections.ZoneAdmission` admits a landed record
  on its linked account's tags against the canonical store's declared zone.
  **Owner-only**: no role can be granted more than `:basic` on it
  (`AshEnterprise.Security.Privilege.owner_only?/1`), so a message is readable
  by the user it was projected for and nobody else in the tenant. The fixture
  calendar adapter is exempt from admission — deterministic synthetic data.

  Projection-derived, so `archival?`/`lifecycle?` are opted out for the same
  reasons as `AshEnterprise.Canonical.Person`: replay reconstructs, soft delete
  would ghost the upsert identity, the lifecycle pair carries no meaning.

  ## Erasure (ADR 0024)

  `body` is sealed under the erasure scope of the SourceObject the message was
  projected from — a projector passes `erasure_scope_id: source.erasure_scope_id`
  and `upsert_from_source` refuses a message without one. The audit event of
  every write carries only the ciphertext (`changed_attributes`
  `encrypted_body`); the `body` input is a sensitive argument and is recorded as
  `nil`. Shredding the scope makes both unreadable; `body` then reads as
  `AshEnterprise.Erasure.Shredded`.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Canonical,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false,
    extra_extensions: [AshCloak]

  postgres do
    table "canonical_messages"
    repo AshEnterprise.Repo

    references do
      reference :erasure_scope, on_delete: :restrict
    end
  end

  cloak do
    vault({AshEnterprise.Erasure.Vault, :resolve, []})
    attributes [:body]
    decrypt_by_default([:body])
    encrypt_nil?(false)
  end

  changes do
    change {AshEnterprise.Erasure.Changes.SealUnderScope, fields: [:body]}, on: [:create, :update]
  end

  attributes do
    uuid_primary_key :id

    attribute :body, :string do
      public? true
      description "The message text, normalized from the source payload."
    end

    attribute :sent_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the message was sent, per the source system."
    end

    attribute :direction, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:inbound, :outbound]
      description "From the operator's point of view: inbound is received mail, outbound is sent."
    end

    attribute :external_system, :string do
      public? true
      constraints max_length: 64
      description "Source-of pair: which external system the message was projected from."
    end

    attribute :external_id, :string do
      public? true
      constraints max_length: 512
      description "Source-of pair: that system's id for the message (Gmail message id, Slack ts)."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :conversation, AshEnterprise.Canonical.Conversation do
      public? true
      attribute_public? true
      allow_nil? true

      description "The thread this message belongs to. Nil until its conversation has been projected."
    end

    belongs_to :sender, AshEnterprise.Canonical.Person do
      public? true
      attribute_public? true
      allow_nil? true

      description "The correspondent (or the operator, for outbound). Nil until their Person row exists."
    end

    belongs_to :erasure_scope, AshEnterprise.Erasure.Scope do
      allow_nil? false
      public? true
      attribute_public? true
      attribute_writable? true

      description "The scope of the SourceObject this message was projected from; its key seals `body`."
    end
  end

  calculations do
    calculate :sent, :string, {AshEnterprise.Platform.Calculations.LocalStamp, field: :sent_at} do
      public? true
      description "When it was sent, on the operator's wall clock."
    end

    calculate :preview, :string, AshEnterprise.Canonical.Calculations.MessagePreview do
      public? true
      description "The body on one line, clipped — for a row in a list of messages."
    end

    calculate :sender_label,
              :string,
              {AshEnterprise.Canonical.Calculations.PersonLabel, relationship: :sender} do
      public? true
      description "The sender's name, else their address."
    end
  end

  identities do
    identity :unique_external, [:external_system, :external_id]
  end

  actions do
    defaults [:read]

    update :mdm_repoint do
      description """
      The person merge's write (ADR 0054): this message's sender moves to the golden
      record a merge folded its person into, and back on the unmerge
      (`AshEnterprise.Mdm.PersonJoins`). Machinery only, never typed in.
      """

      accept [:sender_id]
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
        :body,
        :sent_at,
        :direction,
        :external_system,
        :external_id,
        :conversation_id,
        :sender_id,
        :erasure_scope_id,
        # The ownership columns are NOT NULL; a projector has no actor to
        # derive them from, so it passes them (as CalendarEvent's does).
        :owner_id,
        :owner_type,
        :owning_user_id,
        :owning_business_unit_id
      ]

      upsert? true
      upsert_identity :unique_external

      upsert_fields [
        :encrypted_body,
        :sent_at,
        :direction,
        :conversation_id,
        :sender_id,
        :erasure_scope_id
      ]

      # The business events this write implies, in its transaction (ADR 0051).
      change {AshEnterprise.BusinessEvents.Changes.Derive, subject: :message}
    end
  end

  code_interface do
    define :by_external, args: [:system, :id], not_found_error?: false
    define :upsert_from_source
    define :read
  end
end
