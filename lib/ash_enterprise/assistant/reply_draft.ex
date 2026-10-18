defmodule AshEnterprise.Assistant.ReplyDraft do
  @moduledoc """
  A reply the person drafted to one of their conversations — stored, and
  nothing more.

  There is no send. No send scope exists on any linked account, and this
  resource has no action that delivers anything anywhere: a draft is a row the
  person can read back (in the agent chat, or composed into a table) and copy
  from. The assistant proposes one (`AshEnterprise.AI.Proposal.draft_reply/4`)
  and it is written only when the person confirms, with them as the actor.

  ## Owner-only, sealed under the conversation's scope

  User-owned and owner-only (`AshEnterprise.Security.Privilege.owner_only?/1`):
  the person who drafted it, and nobody else in the tenant. Drafting and
  reading one's own are self-service (ADR 0052).

  The body answers mail or Slack, so it is content in ADR 0024's sense, and it
  is sealed under **the conversation's** erasure scope
  (`AshEnterprise.Assistant.Changes.InheritConversationScope`): forgetting the
  linked account the conversation came through makes its drafts unreadable
  with it. Drafting needs the conversation to be readable by the actor.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Assistant,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false,
    self_service: [:draft, :read, :mine],
    extra_extensions: [AshCloak]

  alias AshEnterprise.Platform.Calculations.RelatedField

  postgres do
    table "assistant_reply_drafts"
    repo AshEnterprise.Repo

    references do
      reference :conversation, on_delete: :delete
      reference :erasure_scope, on_delete: :restrict
    end

    custom_indexes do
      index [:owner_id, :inserted_at]
    end
  end

  cloak do
    vault({AshEnterprise.Erasure.Vault, :resolve, []})
    attributes [:body]
    decrypt_by_default([:body])
    encrypt_nil?(false)
  end

  attributes do
    uuid_primary_key :id

    attribute :body, :string do
      allow_nil? false
      public? true
      # No max_length on a sealed attribute (see Canonical.CalendarEvent).
      description "The reply's text. Sealed under the conversation's scope."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :conversation, AshEnterprise.Canonical.Conversation do
      allow_nil? false
      public? true
      attribute_public? true
      description "The conversation this replies to."
    end

    belongs_to :erasure_scope, AshEnterprise.Erasure.Scope do
      allow_nil? false
      public? true
      attribute_public? true
      attribute_writable? true
      description "The conversation's scope; its key seals the body."
    end
  end

  calculations do
    # Read as the reader (RelatedField), never through a join past
    # Conversation's owner-only policies.
    calculate :conversation_subject,
              :string,
              {RelatedField, relationship: :conversation, field: :subject} do
      public? true
      description "The subject of the conversation this replies to."
    end
  end

  actions do
    defaults [:read]

    read :mine do
      description "The actor's own drafts, newest first."
      filter expr(owner_id == ^actor(:id) and owner_type == :user)
      prepare build(sort: [inserted_at: :desc])
    end

    create :draft do
      description """
      Store a reply draft to one of the actor's conversations. Stored only:
      nothing is sent, and there is no action that sends.
      """

      accept [:conversation_id, :body]

      change set_attribute(:owner_id, actor(:id))
      change set_attribute(:owner_type, :user)
      change set_attribute(:owning_user_id, actor(:id))
      change set_attribute(:owning_business_unit_id, actor(:owning_business_unit_id))
      change AshEnterprise.Assistant.Changes.InheritConversationScope
      change {AshEnterprise.Erasure.Changes.SealUnderScope, fields: [:body]}
    end
  end

  code_interface do
    define :draft, args: [:conversation_id, :body]
    define :mine
  end
end
