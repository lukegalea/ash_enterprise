defmodule AshEnterprise.Execution.Run do
  @moduledoc """
  One durable agent run (ADR 0056): the `AshAgent.Run` fragment on the platform base, in
  table `exec_agent_runs`. A run is rows and a trigger, not a process: the row is its own
  checkpoint, its messages are `AshEnterprise.Execution.Step` rows, and every tool call
  that is not an in-loop read is an `AshEnterprise.Execution.Invocation` row.

  ## What the fragment brings

  The attributes (the pinned `agent_version_id`, `executing_principal`, `status` and
  `blocked_on`, `step_seq`, the counters, the token budget and its holds, `deadline_at`,
  the lease), the lifecycle `queued → running → (waiting) → completed | failed |
  cancelled`, the actions (`start`, `claim_step`, `record_step`, `reserve`, `settle`,
  `extend`, `recover`, `request_cancel`, `step`) and the derived `needs_step`. See
  `AshAgent.Run`, `AshAgent.Run.Stepper` and `AshAgent.Run.Budget`.

  ## What this resource adds

    * **Tenancy and ownership.** Tenant-scoped and user-owned: `start` stamps the person
      who started the run as `owner_id`. Audited (every transition is an event), not
      temporal, no soft delete, and the fragment's state machine instead of the base's
      lifecycle.
    * **Who may do what.** `start` is self-service (ADR 0052): any active member may ask,
      and `AshEnterprise.Execution.Identity.run_principal/3` refuses anyone who does not
      hold the agent's start grant (`AshEnterprise.Security.AgentStartGrant`). The step's
      own writes (`claim_step`, `record_step`, `reserve`, `settle`, `recover`, `step`) are
      machinery-only: only the `oban` system actor reaches them. Reads, `request_cancel`
      and `extend` go through the grant union; a person reads the runs they started.
    * **The token budget (decision D14).** Tokens, as each `AshEnterprise.AI.ModelCall`
      reports them. Every model call holds what is left of the run's budget before it is
      made and is settled after it, under `optimistic_lock(:budget_lock)`, so holds never
      add up past the limit. A run with nothing left waits on its budget
      (`blocked_on: :budget`, `"token_budget"`) until someone who may write runs (an
      administrator) extends it, which queues it again.
    * **Who a run executes as.** The version's publish-time authority: the person who
      started it, or the automation principal the publisher named acting for them (ADR
      0043). Each step rebuilds that actor from grant rows; each tool call is requested
      as the person and runs as the run does.
    * **The model.** `AshEnterprise.Execution.AgentRuntime`: the in-zone profile only,
      through the guarded ReqLLM module, so every call is an `AshEnterprise.AI.ModelCall`
      named `run:<run id>:<step seq>`.
    * **Sealing.** `input` and `output` are sealed under the subject's erasure scope
      (ADR 0024), as an invocation's arguments are
      (`AshEnterprise.Execution.Changes.SealingScope`): a run that names the record it is
      about (`subject_type`, `subject_id`, read as the person starting it) is sealed
      under that record's scope when it has one, any other under the requester's own.
      The run's steps, and its tool calls that act on no sealed record, are sealed under
      the same scope, so shredding a subject's scope erases every copy a run made of
      them while the rows, their transitions and the audit chain stay.
    * **Correlation.** `start` records the correlation id and trace context it ran
      under; every step runs under them again, so a run's audited writes and spans join
      the request that started it.
    * **The `:step` trigger.** `start`, every record that leaves the run queued or
      waiting, and every invocation of the run that finishes
      (`AshAgent.Run.Changes.Wake`) enqueue it in their own transaction; its scheduler
      sweeps any run with a step to take whose job was lost. The action holds no
      transaction: it calls a model.
    * **Following a run.** Every update is published on `agent_runs:<id>`
      (`Ash.Notifier.PubSub`), so a page waiting on it is told when it moves.
    * **The `:recover` trigger.** A running run whose lease expired (its worker died, or
      its model call failed) is queued again. Only the sweep finds them.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Execution,
    ownership: :user_owned,
    lifecycle?: false,
    archival?: false,
    self_service: [:start, :read],
    machinery_only: [:claim_step, :record_step, :reserve, :settle, :recover, :step],
    notifiers: [Ash.Notifier.PubSub],
    extra_extensions: [AshCloak, AshOban],
    fragments: [AshAgent.Run]

  alias AshEnterprise.Execution.AgentRuntime

  postgres do
    table "exec_agent_runs"
    repo AshEnterprise.Repo

    references do
      reference :erasure_scope, on_delete: :restrict
      reference :agent_version, on_delete: :restrict
    end

    # The sweeps' queries, across tenants, every minute.
    custom_indexes do
      index [:status, :lease_expires_at], all_tenants?: true
    end
  end

  # Who follows a run: a page waiting on an answer
  # (`AshEnterprise.Assistant.Ask.topic/1`) hears each transition and step and reads the
  # run again as its person. The message only says the run moved.
  pub_sub do
    module AshEnterpriseWeb.Endpoint
    prefix "agent_runs"

    publish_all :update, [:id]
  end

  run do
    agent_version(AshEnterprise.Execution.AgentVersion)
    step(AshEnterprise.Execution.Step)
    invocation(AshEnterprise.Execution.Invocation)
    runtime(AgentRuntime)
  end

  cloak do
    vault({AshEnterprise.Erasure.Vault, :resolve, []})
    attributes [:input, :output]
    encrypt_nil?(false)
  end

  changes do
    change set_attribute(:owner_id, actor(:id)), on: [:create]
    change set_attribute(:correlation_id, &AgentRuntime.correlation_id/0), on: [:create]
    change set_attribute(:traceparent, &AgentRuntime.traceparent/0), on: [:create]
    change AshEnterprise.Execution.Changes.SealingScope, on: [:create]

    change {AshEnterprise.Erasure.Changes.SealUnderScope, fields: [:input, :output]},
      on: [:create, :update]
  end

  oban do
    triggers do
      # A run with a step to take: queued, or waiting on tool calls that have all
      # finished. The worker is unique per run while a job waits to run, not while one
      # runs: a step that leaves the run queued (its tools were reads it took in its
      # loop) enqueues the next from inside its own job. The claim inside `step` decides
      # when two jobs meet, and the loser ends before any model call.
      trigger :step do
        action :step
        where expr(needs_step)
        read_action :read
        queue :agent_runs
        scheduler_cron "* * * * *"
        max_attempts 3
        worker_opts unique: [period: :infinity, states: [:available, :scheduled, :retryable]]
        use_tenant_from_record? true
        actor_persister :none
        default_actor AshEnterprise.Platform.SystemActor.oban()
        worker_module_name AshEnterprise.Execution.Run.StepWorker
        scheduler_module_name AshEnterprise.Execution.Run.StepScheduler
      end

      # A worker died holding the lease, or its model call failed: queue the run again.
      # Nothing enqueues it; the sweep finds them.
      trigger :recover do
        action :recover
        where expr(status == :running and lease_expires_at <= now())
        read_action :read
        stream_with :full_read
        queue :agent_runs
        scheduler_cron "* * * * *"
        max_attempts 3
        use_tenant_from_record? true
        actor_persister :none
        default_actor AshEnterprise.Platform.SystemActor.oban()
        worker_module_name AshEnterprise.Execution.Run.RecoverWorker
        scheduler_module_name AshEnterprise.Execution.Run.RecoverScheduler
      end
    end
  end

  relationships do
    belongs_to :erasure_scope, AshEnterprise.Erasure.Scope do
      public? true
      description "The erasure scope `input`, `output` and the steps' `parts` are sealed under."
    end

    belongs_to :agent_version, AshEnterprise.Execution.AgentVersion do
      public? true
      define_attribute? false
      description "The version the run is pinned to."
    end

    has_many :steps, AshEnterprise.Execution.Step do
      public? true
      sort seq: :asc
      description "The run's journal, in order."
    end

    has_many :invocations, AshEnterprise.Execution.Invocation do
      public? true
      description "The run's tool calls that are not in-loop reads."
    end
  end
end
