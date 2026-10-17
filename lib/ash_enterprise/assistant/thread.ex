defmodule AshEnterprise.Assistant.Thread do
  @moduledoc """
  One assistant conversation: the person's question-and-answer history at
  `/app/agent`, in `AshEnterprise.Assistant.Turn` rows.

  ## Owner-only

  User-owned, and owner-only (`AshEnterprise.Security.Privilege.owner_only?/1`):
  no role can be granted more than `:basic` on it, so a thread is readable by
  the person who started it and nobody else in the tenant — an
  Administrator included. Starting and reading one's own are self-service
  (ADR 0052): any active member may, with no grant at all.

  ## Sealed, one erasure scope per thread (ADR 0024)

  An answer quotes the person's mail, Slack and calendar, so the history is
  content in the sense the erasure design means. Each thread opens its own
  scope (`data_subject`, ref `assistant_thread:<thread id>` — an opaque id,
  never a name) and its title and every turn's text are sealed under it.
  Shredding that scope makes the conversation unreadable, audit copies
  included; a shredded scope is never reopened, and a new thread opens a
  new one.

  What a thread scope does **not** do is follow the sources an answer drew
  on: an answer is sealed under its thread's key, not its sources'. Each
  turn records the scopes its tool results came from
  (`Turn.source_scope_ids`), and `AshEnterprise.Assistant.History` withholds
  a turn whose source has since been shredded — so a forgotten Slack stops
  showing up in old answers — but its ciphertext stays readable to the
  thread's key until the thread's own scope is shredded. That gap is the
  ADR's "anything derived outside the sealed resources", narrowed, not
  closed.

  `lifecycle?`/`archival?` are opted out: a thread has no state of its own,
  and history is never soft-deleted — erasure is the shred.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Assistant,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false,
    self_service: [:start, :read, :mine],
    extra_extensions: [AshCloak]

  postgres do
    table "assistant_threads"
    repo AshEnterprise.Repo

    references do
      reference :erasure_scope, on_delete: :restrict
    end

    custom_indexes do
      index [:owner_id, :inserted_at]
    end
  end

  cloak do
    vault({AshEnterprise.Erasure.Vault, :resolve, []})
    attributes [:title]
    decrypt_by_default([:title])
    encrypt_nil?(false)
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      public? true
      # No max_length on a sealed attribute (see Canonical.Conversation).
      description "The thread's first question, clipped. Sealed."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :turns, AshEnterprise.Assistant.Turn do
      public? true
      sort inserted_at: :asc
      description "The questions and answers, oldest first."
    end

    belongs_to :erasure_scope, AshEnterprise.Erasure.Scope do
      allow_nil? false
      public? true
      attribute_public? true
      attribute_writable? true
      description "This thread's own scope; its key seals the title and every turn."
    end
  end

  aggregates do
    count :turn_count, :turns do
      public? true
    end

    max :last_turn_at, :turns, :inserted_at do
      public? true
      description "When the latest question or answer was written."
    end
  end

  actions do
    defaults [:read]

    read :mine do
      description "The actor's own threads, most recently active first."
      prepare build(sort: [last_turn_at: :desc_nils_last, inserted_at: :desc])

      pagination offset?: true, default_limit: 30, required?: false
    end

    create :start do
      description """
      Start a thread for the actor: opens its erasure scope and seals the
      title under it.
      """

      accept [:title]

      change set_attribute(:owner_id, actor(:id))
      change set_attribute(:owner_type, :user)
      change set_attribute(:owning_user_id, actor(:id))
      change set_attribute(:owning_business_unit_id, actor(:owning_business_unit_id))
      change AshEnterprise.Assistant.Changes.OpenThreadScope
      change {AshEnterprise.Erasure.Changes.SealUnderScope, fields: [:title]}
    end
  end

  code_interface do
    define :start, args: [:title]
    define :mine
    define :get, action: :read, get_by: [:id]
  end
end
