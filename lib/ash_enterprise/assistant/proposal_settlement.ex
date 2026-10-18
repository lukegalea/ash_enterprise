defmodule AshEnterprise.Assistant.ProposalSettlement do
  @moduledoc """
  What the person did with a proposal the agent chat showed them: confirmed
  it, cancelled it, or confirmed it and it failed.

  A proposal itself is recorded on its answer (`Turn.tool_calls`, the wire
  form under the page's own id). This row is what lets it outlive the page:
  reopening the thread offers a proposal with no settlement again — rebuilt
  from its wire form **as the person** and authorization-checked, exactly as
  when it was first shown — and shows a settled one as what happened to it.

  Append-only, like the turns: `:confirmed` is written **before** the
  proposal runs, and its identity (one per thread, proposal and outcome)
  makes a second confirm from another tab fail instead of running the
  mutation twice; a run that then fails appends `:failed`. Structural only
  (ids and an outcome, never a summary), so nothing here needs sealing; it
  carries its thread's erasure scope so it goes where the thread goes.

  User-owned, owner-only and self-service, like its thread; settling
  requires the thread to be readable by the actor
  (`AshEnterprise.Assistant.Changes.InheritThread`).
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Assistant,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false,
    self_service: [:settle, :read, :for_thread]

  postgres do
    table "assistant_proposal_settlements"
    repo AshEnterprise.Repo

    references do
      reference :thread, on_delete: :restrict
      reference :erasure_scope, on_delete: :restrict
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :proposal_ref, :string do
      allow_nil? false
      public? true
      constraints max_length: 64
      description "The page's id for the proposal (`p…`), as its answer's tool call records it."
    end

    attribute :outcome, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:confirmed, :cancelled, :failed]
      description "confirmed (written before it runs), cancelled, or failed after a confirm."
    end

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
      description "The thread's scope, copied on as the thread's turns copy it."
    end
  end

  identities do
    identity :one_outcome_per_proposal, [:thread_id, :proposal_ref, :outcome]
  end

  actions do
    defaults [:read]

    read :for_thread do
      description "A thread's settlements, oldest first."
      argument :thread_id, :uuid, allow_nil?: false
      filter expr(thread_id == ^arg(:thread_id))
      prepare build(sort: [inserted_at: :asc])
    end

    create :settle do
      description """
      Record what the actor did with one proposal in a thread they may read.
      A second `:confirmed` for the same proposal is refused by the identity.
      """

      accept [:thread_id, :proposal_ref, :outcome]

      change set_attribute(:owner_id, actor(:id))
      change set_attribute(:owner_type, :user)
      change set_attribute(:owning_user_id, actor(:id))
      change set_attribute(:owning_business_unit_id, actor(:owning_business_unit_id))
      change AshEnterprise.Assistant.Changes.InheritThread
    end
  end

  code_interface do
    define :settle, args: [:thread_id, :proposal_ref, :outcome]
    define :for_thread, args: [:thread_id]
  end
end
