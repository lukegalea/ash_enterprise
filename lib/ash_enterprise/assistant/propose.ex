defmodule AshEnterprise.Assistant.Propose do
  @moduledoc """
  The assistant's proposal tools, as computed reads (`AshEnterprise.Assistant`
  declares each one a tool): add or finish an action item, draft a reply,
  sync now. Each answers with one row, the proposal. A read, so a run takes
  it in its loop (`AshEnterprise.Assistant.Lookup`): proposing changes
  nothing, and confirming is the person's own act on the page.

  **None of them changes anything.** Each builds an `AshEnterprise.AI.Proposal`
  — names resolved as the person, the concrete action authorization-checked
  with `Ash.can?` as them — and answers the model with what was proposed. The
  page shows the proposal in the turn; it runs only when the person confirms,
  rebuilt from its wire form as them and executed with them as the actor
  (`AshEnterpriseWeb.AssistantLive`), which is what the audit log records.

  `propose_decision` proposes a decision: approving or rejecting a process
  task (a morning brief's included) the engine says waits on the person, or
  a steward's verdict on a duplicate in their queue. Each is resolved through
  the engine's own answers as the person (`Proposal.decide_task/5`,
  `Proposal.steward_verdict/4`), so a task or duplicate that is not theirs to
  decide is a refusal, never a proposal.

  Self-service (ADR 0052) and zone-gated like the read tools.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Assistant,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    self_service: [:propose_task, :propose_reply, :propose_sync, :propose_decision],
    extra_extensions: [AshAgent.Effects]

  alias AshEnterprise.Assistant.Tools.Proposals

  resource do
    require_primary_key? false
  end

  attributes do
    attribute :proposed, :string, public?: true
    attribute :proposal, :map, public?: true
    attribute :effect, :string, public?: true
    attribute :status, :string, public?: true
  end

  actions do
    read :propose_task do
      description "Propose adding an action item, or marking one done."

      argument :change, :atom do
        allow_nil? false
        constraints one_of: [:add, :done]
        description "add (a new action item) or done (finish one of the person's open ones)."
      end

      argument :title, :string do
        allow_nil? true

        description "add: what is to be done. done: the task's id from my_tasks, or words from its title."
      end

      argument :due, :string do
        allow_nil? true
        description "add only: today, tomorrow or a date like 2026-10-20. Leave out for none."
      end

      manual {Proposals, kind: :task}
    end

    read :propose_reply do
      description "Propose saving a reply draft to a conversation. It is never sent."

      argument :conversation, :string do
        allow_nil? false
        description "The conversation's ref (inbox:… or slack:…) from find_conversations."
      end

      argument :text, :string do
        allow_nil? false
        description "The reply, in the person's voice."
      end

      manual {Proposals, kind: :reply}
    end

    read :propose_sync do
      description "Propose syncing the person's linked accounts now."

      argument :account, :atom do
        allow_nil? true
        constraints one_of: [:gmail, :slack, :calendar, :all]
        description "gmail, slack, calendar or all (default all)."
      end

      manual {Proposals, kind: :sync}
    end

    read :propose_decision do
      description "Propose deciding a task waiting on the person, or a duplicate in their steward queue."

      argument :on, :atom do
        allow_nil? false
        constraints one_of: [:task, :duplicate]
        description "task (from pending_approvals) or duplicate (from steward_queue)."
      end

      argument :decision, :atom do
        allow_nil? false
        constraints one_of: [:approve, :reject, :merge, :keep_separate, :unsure]

        description "task: approve or reject. duplicate: merge, keep_separate or unsure."
      end

      argument :target, :string do
        allow_nil? true

        description "Its ref from the lookup, or words from its name. Leave out when only one waits."
      end

      argument :comment, :string do
        allow_nil? true
        constraints max_length: 2000
        description "task only: a note recorded with the decision."
      end

      manual {Proposals, kind: :decision}
    end
  end

  # The assistant's proposal tools (ADR 0057): each builds a proposal and
  # changes nothing; the person confirms the proposal itself, which then runs
  # as them.
  effects do
    action :propose_task,
      kind: :think,
      read_only?: true,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :propose

    action :propose_reply,
      kind: :think,
      read_only?: true,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :propose

    action :propose_sync,
      kind: :think,
      read_only?: true,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :propose

    action :propose_decision,
      kind: :think,
      read_only?: true,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :propose
  end
end
