defmodule AshEnterprise.Assistant.Turn do
  @moduledoc """
  One question or one answer in an `AshEnterprise.Assistant.Thread`.

  Append-only: there is no update and no destroy. An answer is written once,
  when its run ends — complete, stopped by the person, or failed — with
  whatever text it had; a retry is a new answer to the same question.

  ## What is sealed and what is not

  Sealed under the thread's scope (ADR 0024): `content` (the question, or
  the answer with its `[[ref]]` citations) and `tool_calls` (each call's
  name, arguments, row count and outcome — arguments carry the names and
  search text the person asked about). Structural and plaintext: `role`,
  `status`, `error_class` (an exception module or a reason atom, never a
  message), `refs` (the `<surface>:<id>` records the tools returned, which
  are the only citations the page will link), `source_scope_ids` (which
  erasure scopes those records came from), `iterations` and `duration_ms`.

  Owner-only and self-service, like its thread; appending requires the
  thread to be readable by the actor (`AshEnterprise.Assistant.Changes.InheritThread`).
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Assistant,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false,
    self_service: [:append, :read, :for_thread],
    extra_extensions: [AshCloak]

  postgres do
    table "assistant_turns"
    repo AshEnterprise.Repo

    references do
      reference :thread, on_delete: :restrict
      reference :erasure_scope, on_delete: :restrict
    end

    custom_indexes do
      index [:thread_id, :inserted_at]
    end
  end

  cloak do
    vault({AshEnterprise.Erasure.Vault, :resolve, []})
    attributes [:content, :tool_calls]
    decrypt_by_default([:content, :tool_calls])
    encrypt_nil?(false)
  end

  attributes do
    uuid_primary_key :id, writable?: true

    attribute :role, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:user, :assistant]
    end

    attribute :content, :string do
      public? true
      description "The question, or the answer as the model wrote it. Sealed."
    end

    attribute :tool_calls, :map do
      public? true
      default %{}

      description """
      `%{"calls" => [%{"name", "arguments", "count", "ok"}]}`: what the answer
      looked up, in order. Sealed.
      """
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :complete
      constraints one_of: [:complete, :stopped, :failed]
      description "How the run that wrote this answer ended. A question is always complete."
    end

    attribute :error_class, :string do
      public? true
      constraints max_length: 200
      description "Why a failed run failed: a reason atom or exception module, never its message."
    end

    attribute :refs, {:array, :string} do
      public? true
      default []
      description "`<surface>:<id>` of every record the tools returned: the citable records."
    end

    attribute :source_scope_ids, {:array, :uuid} do
      public? true
      default []
      description "The erasure scopes the returned records were sealed under."
    end

    attribute :iterations, :integer, public?: true, constraints: [min: 0]
    attribute :duration_ms, :integer, public?: true, constraints: [min: 0]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :thread, AshEnterprise.Assistant.Thread do
      allow_nil? false
      public? true
      attribute_public? true
    end

    belongs_to :erasure_scope, AshEnterprise.Erasure.Scope do
      allow_nil? false
      public? true
      attribute_public? true
      attribute_writable? true
      description "The thread's scope, copied onto the turn so the seal names it."
    end
  end

  actions do
    defaults [:read]

    read :for_thread do
      description "A thread's turns, oldest first."
      argument :thread_id, :uuid, allow_nil?: false
      filter expr(thread_id == ^arg(:thread_id))
      prepare build(sort: [inserted_at: :asc])
    end

    create :append do
      description """
      Append one question or answer to a thread the actor may read. `id` may
      be given, so a run and the page that stops it write the same answer at
      most once.
      """

      accept [
        :id,
        :thread_id,
        :role,
        :content,
        :tool_calls,
        :status,
        :error_class,
        :refs,
        :source_scope_ids,
        :iterations,
        :duration_ms
      ]

      change set_attribute(:owner_id, actor(:id))
      change set_attribute(:owner_type, :user)
      change set_attribute(:owning_user_id, actor(:id))
      change set_attribute(:owning_business_unit_id, actor(:owning_business_unit_id))
      change AshEnterprise.Assistant.Changes.InheritThread
      change {AshEnterprise.Erasure.Changes.SealUnderScope, fields: [:content, :tool_calls]}
    end
  end

  code_interface do
    define :append
    define :for_thread, args: [:thread_id]
  end
end
