defmodule AshEnterprise.Canonical.Task do
  @moduledoc """
  A commitment with a status (dogfood §11): captured by the operator or
  extracted from a message by a later epic. `source` records where it came
  from — provenance is mandatory, not decoration.

  Projection-derived, so `archival?`/`lifecycle?` are opted out for the same
  reasons as `AshEnterprise.Canonical.Person`: replay reconstructs, soft delete
  would ghost the upsert identity, and `status` below is this resource's own
  lifecycle — a Dataverse Active/Inactive pair beside it would be two answers
  to one question.

  ## A person's own action items (ADR 0052)

  Any active member may capture an action item for themselves (`:capture`),
  read their own (`:mine`, `:due_today`) and move one of their own between
  lanes or mark it done with no role grant. The moves are generic actions
  because a self-service update cannot be declared: each finds the task
  through `:mine`, as the actor, so it reaches only a row the actor owns, and
  only then runs one guarded update on it
  (`AshEnterprise.Canonical.Actions.ActOnOwnTask`). That write is the actor's
  own act on their own row, recorded under their name in the audit log; every
  other update to a task still takes a role grant.

  ## One list of action items (PROD-18)

  The Action items surface (`AshEnterpriseWeb.A2ui.ActionItemsUI`) is a board
  over the actor's own tasks, in lanes: **Inbox** (captured, not yet sorted),
  **Today**, **Later** and **Done**. `plan` is where the person put an open
  task; `lane` derives the board column from it and `status`.

  | Self-service action | Update | Allowed from |
  |---|---|---|
  | `plan_today_mine` | `:plan_today` | an open task |
  | `plan_later_mine` | `:plan_later` | an open task |
  | `complete_mine` | `:complete` | an open task |
  | `reopen_mine` | `:reopen` | a done or dropped task; it returns to the lane it left |
  | `drop_mine` | `:drop` | an open task (cancelled: no longer wanted) |

  The updates check the status themselves; the board's `visible_when` only
  decides which buttons a card shows.

  `origin_type` / `origin_id` name the record a task came from (a
  conversation, an event), and `origin_ref` turns them into a link that opens
  it, re-read as whoever follows it.

  ## Proposals (ADR 0047)

  A commitment found in the person's sent mail or Slack, or a follow-up to a
  meeting they had, arrives as a task in status `:proposed` (the Proposed
  lane), written by the proposer system actor (`:propose`,
  `AshEnterprise.Canonical.Commitments`). It is on no list until its owner
  accepts it:

  | Self-service action | Update | Allowed from |
  |---|---|---|
  | `accept_mine` | `:accept` | a proposal; it lands in Inbox |
  | `dismiss_mine` | `:dismiss` | a proposal (cancelled) |

  Both updates refuse any actor that is not a person, so the proposer
  cannot decide what it proposed. `proposer` and `instrument` keep the
  proposal's lineage: which proposer, which model in which zone.

  ## Erasure (ADR 0024)

  A proposal's words are canonical content: `commitment` (the action item as
  extracted) and `evidence` (the words it was found in) are sealed under the
  erasure scope of the message or meeting they came from
  (`AshEnterprise.Erasure.Changes.SealUnderScope`), and read as
  `AshEnterprise.Erasure.Shredded` once that scope is shredded. `title`
  stays plain for what a person typed; for a proposal it is a structural
  stand-in (`Proposed from gmail`), never the words. `label` is what every
  surface shows: the sealed commitment when there is one, else the title.

  ## A judged question (S1-53)

  `:task_actionable` is a declared System One question about the title.
  `AshEnterprise.SystemOne.JudgedFields` derives `task_actionable`,
  `task_actionable_status` and `task_actionable_reason` from it — fields
  that read the facts table in the task's own query — and keeps
  `judgment_digests` current, so a retitled task's fact reads stale and
  the `:reassess_judgments` trigger is enqueued. Changing the status, the
  plan or the due date touches no projection field and enqueues nothing.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Canonical,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false,
    self_service: [
      :capture,
      :mine,
      :due_today,
      :complete_mine,
      :plan_today_mine,
      :plan_later_mine,
      :reopen_mine,
      :drop_mine,
      :accept_mine,
      :dismiss_mine
    ],
    notifiers: [Ash.Notifier.PubSub],
    extra_extensions: [
      AshCloak,
      AshAi,
      AshJudgments.Registry,
      AshOban,
      AshEnterprise.SystemOne.JudgedFields
    ]

  postgres do
    table "canonical_tasks"
    repo AshEnterprise.Repo

    references do
      reference :erasure_scope, on_delete: :restrict
    end
  end

  cloak do
    vault({AshEnterprise.Erasure.Vault, :resolve, []})
    attributes [:commitment, :evidence]
    decrypt_by_default([:commitment, :evidence])
    encrypt_nil?(false)
  end

  changes do
    change {AshEnterprise.Erasure.Changes.SealUnderScope, fields: [:commitment, :evidence]},
      on: [:create, :update]
  end

  # What keeps the Action items board and Today live: a capture over ACP, or
  # a move or a completion on another page, refreshes every open page, which
  # re-reads as its own actor (`AshEnterprise.Surfaces.topics/1` reads these).
  pub_sub do
    module AshEnterpriseWeb.Endpoint
    prefix "canonical_tasks"

    publish_all :create, ["created"]
    publish_all :update, ["updated"]
  end

  judgments do
    question :task_actionable do
      type AshAi.Evaluate.Noul

      instructions(
        "Does the task title name one concrete action a person could start on and later check as done?"
      )

      version(1)
      family(:canonical_tasks)
      profile(:laya_cpu)
      pii(:minimised)
      state_projection(AshEnterprise.SystemOne.JudgedFields.RecordState)
      state_shape(%{"title" => "string"})
    end
  end

  oban do
    triggers do
      # Enqueued by the task's own write when it turns a judged fact stale
      # (AshEnterprise.SystemOne.JudgedFields.MaintainDigests); never polled.
      trigger :reassess_judgments do
        action :reassess_judgments
        queue :system_one
        scheduler_cron false
        max_attempts 3
        default_actor AshEnterprise.Platform.SystemActor.oban()
        worker_module_name AshEnterprise.Canonical.Task.ReassessJudgmentsWorker
        scheduler_module_name AshEnterprise.Canonical.Task.ReassessJudgmentsScheduler
      end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints max_length: 1024
      description "What is to be done."
    end

    attribute :due_at, :utc_datetime_usec do
      public? true
      description "When it is due, if it is."
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:proposed, :open, :done, :cancelled]
      default :open

      description """
      The commitment's state: `proposed` until its owner accepts a proposal,
      then open until it is done or cancelled.
      """
    end

    attribute :commitment, :string do
      public? true

      # No max_length on a sealed attribute: a failed constraint renders the
      # value into the error message, which no shred reaches (ADR 0024).
      description "A proposal's action item as extracted from its source. Sealed."
    end

    attribute :evidence, :string do
      public? true
      description "The words in the source the proposal was found in. Sealed."
    end

    attribute :proposer, :string do
      public? true
      constraints max_length: 255

      description "For a proposal: which proposer made it, with its version (`message_commitments/1`)."
    end

    attribute :instrument, :string do
      public? true
      constraints max_length: 255

      description """
      For a proposal: what the proposer read with — the in-zone model's
      label and zone, or `deterministic`.
      """
    end

    attribute :plan, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:inbox, :today, :later]
      default :inbox

      description """
      Where the person put an open task: `inbox` (captured, not yet sorted),
      `today` or `later`. Kept when the task is done, so reopening returns it
      to the lane it left.
      """
    end

    attribute :source, :string do
      allow_nil? false
      public? true
      constraints max_length: 64
      description "Where the task came from: manual, assistant, acp, gmail, slack, calendar."
    end

    attribute :origin_type, :string do
      public? true
      constraints max_length: 255

      description """
      The resource the task came from, as the engine names a subject
      (`"Elixir.AshEnterprise.Canonical.Conversation"`): the commitment's
      thread, the meeting it follows up. Nil for a task typed in.
      """
    end

    attribute :origin_id, :uuid do
      public? true
      description "The id of the record the task came from."
    end

    attribute :external_system, :string do
      public? true
      constraints max_length: 64
      description "Source-of pair: which external system the task was projected from."
    end

    attribute :external_id, :string do
      public? true
      constraints max_length: 512
      description "Source-of pair: that system's id for the task."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :erasure_scope, AshEnterprise.Erasure.Scope do
      allow_nil? true
      public? true
      attribute_public? true
      attribute_writable? true

      description """
      For a task from a source (a proposal and what it became): the scope of
      the message or meeting it came from, whose key seals its words. Nil for
      a task typed in.
      """
    end
  end

  identities do
    identity :unique_external, [:external_system, :external_id]
  end

  actions do
    defaults [:read]

    read :mine do
      description "The actor's own tasks, soonest due first."
      filter expr(owner_id == ^actor(:id) and owner_type == :user)
      prepare build(sort: [due_at: :asc_nils_last, inserted_at: :desc])
    end

    read :due_today do
      description """
      The actor's own open tasks for today: planned for today, or due before
      the end of today on the display zone's clock (overdue included),
      soonest due first. What Today's action-items section and the `today`
      digest list.
      """

      filter expr(owner_id == ^actor(:id) and owner_type == :user and status == :open)
      prepare AshEnterprise.Canonical.Preparations.DueToday
    end

    create :capture do
      description """
      Capture an open action item for the actor, owned by them, into their
      Inbox. `source` records where it came from: `manual` (typed in),
      `assistant` (proposed in the agent chat and confirmed by the person) or
      `acp` (said as `todo …` in the terminal).
      """

      accept [:title, :due_at]

      argument :source, :atom do
        allow_nil? false
        default :manual
        constraints one_of: [:manual, :assistant, :acp]
      end

      change set_attribute(:status, :open)
      change set_attribute(:plan, :inbox)
      change set_attribute(:source, arg(:source))
      change set_attribute(:owner_id, actor(:id))
      change set_attribute(:owner_type, :user)
      change set_attribute(:owning_user_id, actor(:id))
      change set_attribute(:owning_business_unit_id, actor(:owning_business_unit_id))
    end

    create :propose do
      description """
      Propose an action item for its owner, from a source record (ADR 0047):
      written by the proposer system actor, in status `:proposed`. The words
      are sealed under the source's erasure scope; the title is structural.
      """

      accept [
        :commitment,
        :evidence,
        :due_at,
        :source,
        :origin_type,
        :origin_id,
        :external_system,
        :external_id,
        :erasure_scope_id,
        :proposer,
        :instrument,
        :owner_id,
        :owning_user_id,
        :owning_business_unit_id
      ]

      validate present([:commitment, :erasure_scope_id, :proposer, :instrument, :owner_id])

      change set_attribute(:status, :proposed)
      change set_attribute(:plan, :inbox)
      change set_attribute(:owner_type, :user)
      change AshEnterprise.Canonical.Changes.ProposalTitle
    end

    update :accept do
      description "Accept a proposal: it becomes an open task in the Inbox. A person's act."
      accept []
      validate attribute_equals(:status, :proposed), message: "only a proposal can be accepted"
      validate AshEnterprise.Canonical.Validations.ByAPerson
      change set_attribute(:status, :open)
      change set_attribute(:plan, :inbox)
    end

    update :dismiss do
      description "Dismiss a proposal: it is not wanted (cancelled). A person's act."
      accept []
      validate attribute_equals(:status, :proposed), message: "only a proposal can be dismissed"
      validate AshEnterprise.Canonical.Validations.ByAPerson
      change set_attribute(:status, :cancelled)
    end

    update :complete do
      description "Mark an open task done."
      accept []
      validate attribute_equals(:status, :open), message: "only an open task can be marked done"
      change set_attribute(:status, :done)
    end

    update :plan_today do
      description "Put an open task on today's list."
      accept []
      validate attribute_equals(:status, :open), message: "only an open task can be planned"
      change set_attribute(:plan, :today)
    end

    update :plan_later do
      description "Put an open task off until later."
      accept []
      validate attribute_equals(:status, :open), message: "only an open task can be planned"
      change set_attribute(:plan, :later)
    end

    update :reopen do
      description "Reopen a done or dropped task; it returns to the lane it left."
      accept []

      validate attribute_in(:status, [:done, :cancelled]),
        message: "only a done or dropped task can be reopened"

      change set_attribute(:status, :open)
    end

    update :drop do
      description "Drop an open task: it is no longer wanted (cancelled)."
      accept []
      validate attribute_equals(:status, :open), message: "only an open task can be dropped"
      change set_attribute(:status, :cancelled)
    end

    # The self-service moves (ADR 0052, note of 2026-10-17): each finds the
    # task through `:mine` as the actor, then runs one guarded update above.
    # `record_id` is what an A2UI row action passes.
    action :complete_mine, :struct do
      description "Mark one of the actor's own open tasks done. Another person's task is not found."
      constraints instance_of: __MODULE__

      argument :record_id, :uuid,
        allow_nil?: false,
        description: "The task (one of the actor's own)."

      run {AshEnterprise.Canonical.Actions.ActOnOwnTask, update: :complete}
    end

    action :plan_today_mine, :struct do
      description "Put one of the actor's own open tasks on today's list."
      constraints instance_of: __MODULE__

      argument :record_id, :uuid,
        allow_nil?: false,
        description: "The task (one of the actor's own)."

      run {AshEnterprise.Canonical.Actions.ActOnOwnTask, update: :plan_today}
    end

    action :plan_later_mine, :struct do
      description "Put one of the actor's own open tasks off until later."
      constraints instance_of: __MODULE__

      argument :record_id, :uuid,
        allow_nil?: false,
        description: "The task (one of the actor's own)."

      run {AshEnterprise.Canonical.Actions.ActOnOwnTask, update: :plan_later}
    end

    action :reopen_mine, :struct do
      description "Reopen one of the actor's own done or dropped tasks."
      constraints instance_of: __MODULE__

      argument :record_id, :uuid,
        allow_nil?: false,
        description: "The task (one of the actor's own)."

      run {AshEnterprise.Canonical.Actions.ActOnOwnTask, update: :reopen}
    end

    action :drop_mine, :struct do
      description "Drop one of the actor's own open tasks: no longer wanted."
      constraints instance_of: __MODULE__

      argument :record_id, :uuid,
        allow_nil?: false,
        description: "The task (one of the actor's own)."

      run {AshEnterprise.Canonical.Actions.ActOnOwnTask, update: :drop}
    end

    action :accept_mine, :struct do
      description "Accept one of the actor's own proposals: it lands in their Inbox."
      constraints instance_of: __MODULE__

      argument :record_id, :uuid,
        allow_nil?: false,
        description: "The proposal (one of the actor's own)."

      run {AshEnterprise.Canonical.Actions.ActOnOwnTask, update: :accept}
    end

    action :dismiss_mine, :struct do
      description "Dismiss one of the actor's own proposals."
      constraints instance_of: __MODULE__

      argument :record_id, :uuid,
        allow_nil?: false,
        description: "The proposal (one of the actor's own)."

      run {AshEnterprise.Canonical.Actions.ActOnOwnTask, update: :dismiss}
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
        :title,
        :due_at,
        :status,
        :source,
        :origin_type,
        :origin_id,
        :external_system,
        :external_id,
        :owner_id,
        :owner_type,
        :owning_user_id,
        :owning_business_unit_id
      ]

      upsert? true
      upsert_identity :unique_external
      upsert_fields [:title, :due_at, :status, :source, :judgment_digests]
    end
  end

  calculations do
    # The board column: where an open task was put, or how it ended.
    calculate :lane,
              :atom,
              expr(
                cond do
                  status == :proposed -> :proposed
                  status == :done -> :done
                  status == :cancelled -> :dropped
                  plan == :today -> :today
                  plan == :later -> :later
                  true -> :inbox
                end
              ) do
      public? true
      constraints one_of: [:proposed, :inbox, :today, :later, :done, :dropped]
      description "The Action items lane: proposed, inbox, today, later, done (or dropped)."
    end

    calculate :label, :string, AshEnterprise.Canonical.Calculations.TaskLabel do
      public? true

      description """
      What the task says, as every surface shows it: the sealed commitment
      of a task from a source (`[shredded]` once its scope is shredded),
      else the title a person typed.
      """
    end

    calculate :due, :string, AshEnterprise.Canonical.Calculations.TaskDue do
      public? true

      description """
      When it is due, on the display zone's clock (`Mon 12 Oct 17:00`, with
      `· overdue` once past for an open task); nil when it has no due date.
      """
    end

    # Structural, never content: what kind of record the task came from.
    calculate :origin_label,
              :string,
              expr(
                cond do
                  is_nil(origin_id) -> nil
                  source == "gmail" -> "Gmail thread"
                  source == "slack" -> "Slack conversation"
                  source == "calendar" -> "Calendar event"
                  true -> "Where it came from"
                end
              ) do
      public? true

      description "The kind of record the task came from (`Gmail thread`); nil for a task typed in."
    end

    calculate :origin_ref, :string, AshEnterprise.Canonical.Calculations.OriginRef do
      public? true

      description """
      The record the task came from as a typed reference, `<surface>:<id>`
      (the `record` link target); nil for a task typed in.
      """
    end
  end

  code_interface do
    define :by_external, args: [:system, :id], not_found_error?: false
    define :upsert_from_source
    define :read
    define :mine
    define :due_today
    define :capture, args: [:title]
    define :complete_mine, args: [:record_id]
    define :plan_today_mine, args: [:record_id]
    define :plan_later_mine, args: [:record_id]
    define :reopen_mine, args: [:record_id]
    define :drop_mine, args: [:record_id]
    define :accept_mine, args: [:record_id]
    define :dismiss_mine, args: [:record_id]
    define :propose
  end
end
