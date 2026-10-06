defmodule AshEnterprise.Canonical.Message do
  @moduledoc """
  The §11 email/Slack message row: one sent or received item in a conversation,
  with its sender, timestamp and direction.

  PERSONAL DATA — DO NOT WIRE A REAL PROJECTOR YET (ADR 0042). Gmail and Slack
  SourceObjects are personal data that is NOT admitted into any declared zone:
  zone admission is not on the SourceObject land path (an E1 follow-up owns
  that). TODO(E4/Gmail+Slack verticals): before enabling a Message projector,
  zone admission must check each landed item's residency tag at `land` time.
  The fixture calendar adapter is exempt — deterministic synthetic data, no
  admission required.

  Projection-derived, so `archival?`/`lifecycle?` are opted out for the same
  reasons as `AshEnterprise.Canonical.Person`: replay reconstructs, soft delete
  would ghost the upsert identity, the lifecycle pair carries no meaning.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Canonical,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false

  postgres do
    table "canonical_messages"
    repo AshEnterprise.Repo
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
        :body,
        :sent_at,
        :direction,
        :external_system,
        :external_id,
        :conversation_id,
        :sender_id
      ]

      upsert? true
      upsert_identity :unique_external

      upsert_fields [
        :body,
        :sent_at,
        :direction,
        :conversation_id,
        :sender_id
      ]
    end
  end

  code_interface do
    define :by_external, args: [:system, :id], not_found_error?: false
    define :upsert_from_source
    define :read
  end
end
