defmodule AshEnterprise.Execution.Invocation do
  @moduledoc """
  One governed invocation (ADR 0055): the `AshAgent.Invocation` fragment on the platform
  base, in table `exec_invocations`.

  ## What the fragment brings

  The attributes, the lifecycle (`requested → awaiting_approval → ready → executing →
  (dispatched) → succeeded | failed | outcome_unknown`, plus `rejected`, `stale`,
  `cancelled`), the actions, typed failure and reconciliation. See the fragment's docs,
  `AshAgent.Invocation.Executor` and `AshAgent.Invocation.Reconciler`.

  ## What this resource adds

    * **Tenancy and ownership.** Tenant-scoped and user-owned: `request` stamps the
      requesting person as `owner_id`. Audited (every transition is an event), not
      temporal (ADR 0049 keeps temporal for validity; this is a state machine with
      history), no soft delete, and the fragment's state machine instead of the base's
      lifecycle (`lifecycle?: false`, spike S9).
    * **Who may do what.** `invoke`, `request` and `confirm` are self-service (ADR 0052):
      any active member may ask on their own behalf, `request` creates only rows they own,
      and `confirm` approves only a request whose declaration lets its requester confirm
      it (`AshEnterprise.Execution.Actions.ConfirmRequest`).
      Every action the job runner drives (`claim`, the completions, `apply_decision`,
      `requeue`, the resolution actions, `execute`, `reconcile`) is machinery-only (ADR
      0059): only the `oban` system actor reaches them, and no grant does. Reads,
      `request_cancel` and `retry` go through the grant union.
    * **The parent.** A request may name only a parent its requester owns
      (`AshEnterprise.Execution.Validations.OwnsParent`), so calling `request` directly
      gains nothing over `invoke`.
    * **Sealing.** `args` and `result` are sealed under an erasure scope (ADR 0024): the
      subject's when the target acts on a record that has one; for an agent run's tool
      call with no such subject, its run's (the run's subject's, when it names one);
      otherwise the requester's own (`AshEnterprise.Execution.Changes.SealingScope`).
      `args_digest` is an HMAC under a key derived from that scope's key
      (`AshEnterprise.Execution.DigestKey`), so a shred makes both unreadable and the
      digest unrecomputable; `recorded?` is then false. No plaintext copy is derived
      (spike S2).
    * **Identity.** `AshEnterprise.Execution.Identity` names the principal (a person, or
      an automation principal acting for one, ADR 0043) and rebuilds its `ActorContext`
      from grant rows at every claim.
    * **Approvals.** A target whose declaration asks for one waits in
      `awaiting_approval` on a standalone task, `invocation.approval`, opened by
      `request` (`AshEnterprise.Execution.Changes.RequestApproval`) for the holders of
      the declaration's `approver_role` (under four eyes, not the requester) and decided
      through the existing `HumanTask.approve` and `reject` doors, which only a person
      may run. The `:apply_decision` trigger applies the decision
      (`AshEnterprise.Execution.Changes.ReadApproval`); never `on_complete`. The
      fragment binds the approval to the request (`authorization_details`,
      `approval_digest`, `approval_expires_at`) and finds the row `stale` when the
      subject, the target or the clock has moved on; every claim also re-checks that
      the approver still may approve (`AshEnterprise.Execution.Changes.RecheckApprover`).
      What an approval rests on is recorded as `approval_basis`, including a
      self-approval under the opt-in sole-administrator rule.
      See `AshEnterprise.Execution.Approval`. Being asked to approve a row lets a person
      read it (`AshEnterprise.Security.Checks.InvocationApprovalCandidacy`).
    * **The `:execute` trigger.** `request` and `apply_decision` enqueue it for every
      ready row in their own transaction; its scheduler sweeps any ready row whose job
      was lost. It takes the tenant from the row, persists no actor, and runs a generic
      action that holds no transaction (spike S5).
    * **The `:reconcile` trigger.** Settles a row whose worker died (its lease expired),
      whose dispatch deadline passed, or whose outcome is unknown: an internal or
      idempotent target is re-readied; any other outside target's row becomes
      `outcome_unknown`, is looked up through its `reconcile_with` action, and otherwise
      waits for a person.
    * **Resolution by a person.** `request_resolution` opens a standalone task,
      `invocation.resolution`, for the tenant's administrators
      (`AshEnterprise.Execution.Changes.OpenResolutionTask`). They decide it through
      `HumanTask.resolve` with `succeeded`, `failed` or `retry`
      (`AshEnterprise.Execution.Resolution`), and the `:apply_resolution` trigger applies
      the decision (`AshEnterprise.Execution.Changes.ReadResolution`). Never
      `on_complete`.
    * **An agent run's tool calls.** A run's call that is not an in-loop read is one of
      these rows, keyed `run:<run id>:<step seq>:<tool call id>` with the run as its
      parent; when it finishes it wakes the run (`AshAgent.Run.Changes.Wake`), and the
      run's next step reads its recorded result. See `AshEnterprise.Execution.Run`.
    * **An agent asking a person.** A run's call to `AshEnterprise.Execution.HumanInput`
      is `dispatched` with its input task, `invocation.input`, opened in the same
      transaction for the person the run acts for
      (`AshEnterprise.Execution.Changes.OpenInputTask`). Nothing runs while they have not
      answered. They answer through `HumanTask.answer`, and the `:collect_input` trigger
      completes the row with their answer as its `result`
      (`AshEnterprise.Execution.Actions.CollectInput`), which wakes the run.
    * **Failure classes for the provider edge.** `AshEnterprise.Integration.ProxyError`
      implements `AshAgent.FailureClass` (`AshEnterprise.Execution.ProxyFailure`).
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Execution,
    ownership: :user_owned,
    lifecycle?: false,
    archival?: false,
    self_service: [:invoke, :request, :confirm],
    machinery_only: [
      :claim,
      :succeed,
      :fail,
      :defer,
      :dispatch,
      :mark_outcome_unknown,
      :mark_stale,
      :requeue,
      :complete_external,
      :request_resolution,
      :apply_resolution,
      :apply_decision,
      :execute,
      :reconcile,
      :collect_input
    ],
    extra_grants: [AshEnterprise.Security.Checks.InvocationApprovalCandidacy],
    notifiers: [Ash.Notifier.PubSub],
    extra_extensions: [AshCloak, AshOban],
    fragments: [AshAgent.Invocation]

  postgres do
    table "exec_invocations"
    repo AshEnterprise.Repo

    references do
      reference :erasure_scope, on_delete: :restrict
    end

    # The `:execute` sweep's query, across tenants, every minute.
    custom_indexes do
      index [:status, :next_attempt_at], all_tenants?: true
    end
  end

  invocation do
    execution_identity(AshEnterprise.Execution.Identity)
    digest_key(AshEnterprise.Execution.DigestKey)
  end

  # Whoever waits on one row hears it move: `invocations:<id>` carries every update
  # (a coding agent's tool call waits on its decision, `AshEnterprise.Agents.OmpSession`).
  pub_sub do
    module AshEnterpriseWeb.Endpoint
    prefix "invocations"

    publish_all :update, [:id]
  end

  cloak do
    vault({AshEnterprise.Erasure.Vault, :resolve, []})
    attributes [:args, :result]
    encrypt_nil?(false)
  end

  changes do
    change set_attribute(:owner_id, actor(:id)), on: [:create]
    change AshEnterprise.Execution.Changes.SealingScope, on: [:create]

    change {AshEnterprise.Erasure.Changes.SealUnderScope, fields: [:args, :result]},
      on: [:create, :update]

    change AshEnterprise.Execution.Changes.HandoffFaultPoints, on: [:create]

    change AshEnterprise.Execution.Changes.RequestApproval, where: [action_is(:request)]
    change AshEnterprise.Execution.Changes.ReadApproval, where: [action_is(:apply_decision)]
    change AshEnterprise.Execution.Changes.RecheckApprover, where: [action_is(:claim)]

    change AshEnterprise.Execution.Changes.OpenResolutionTask,
      where: [action_is(:request_resolution)]

    change AshEnterprise.Execution.Changes.ReadResolution, where: [action_is(:apply_resolution)]
    change AshEnterprise.Execution.Changes.OpenInputTask, where: [action_is(:dispatch)]

    # A run's tool call that finishes wakes its run, in the same transaction.
    change {AshAgent.Run.Changes.Wake, run: AshEnterprise.Execution.Run}, on: [:update]
  end

  attributes do
    # What an approval rests on (ADR 0055, amended 2026-11-01), recorded when the
    # decision is applied (`AshEnterprise.Execution.Changes.ReadApproval`), so a reader
    # can tell a self-approval under the sole-administrator rule from four eyes.
    attribute :approval_basis, :atom do
      public? true
      constraints one_of: [:confirm, :four_eyes, :sole_administrator]

      description """
      What the approval rests on: `:confirm` (the requester confirmed), `:four_eyes`
      (a second person approved) or `:sole_administrator` (the organization's only
      administrator approved their own request, under the opt-in rule). Nil until
      approved, and for rows that needed no approval.
      """
    end
  end

  actions do
    # A person's own request, confirmed by them and run now: what an ACP prompt that
    # asked permission runs once they allow it (`AshEnterprise.Acp.Approvals`).
    action :confirm, :string do
      description """
      Confirm a request of your own: invoke `target` with `args` under `key`, approve it
      yourself where its declaration lets the requester confirm it, and run it now.
      """

      argument :target, :string, allow_nil?: false
      argument :args, :map, allow_nil?: false, default: %{}
      argument :key, :string, allow_nil?: false, constraints: [max_length: 512]

      run AshEnterprise.Execution.Actions.ConfirmRequest
    end

    action :collect_input, :atom do
      description "Complete a dispatched question from its answered or cancelled task."

      constraints one_of: AshEnterprise.Execution.Actions.CollectInput.outcomes()

      argument :primary_key, :map, allow_nil?: false

      run AshEnterprise.Execution.Actions.CollectInput
    end
  end

  validations do
    validate AshEnterprise.Execution.Validations.OwnsParent, on: [:create]
  end

  oban do
    triggers do
      # The ready row's job, enqueued in the transaction that made it ready. The
      # scheduler is the sweep: a ready row whose job was lost (pruned, cancelled, a
      # failed insert after a manual repair) is picked up within a minute. The worker is
      # unique per row while a job is pending, so the sweep never doubles one up, and
      # the claim inside `execute` is what decides when two runs meet.
      trigger :execute do
        action :execute
        where expr(status == :ready and (is_nil(next_attempt_at) or next_attempt_at <= now()))
        read_action :read
        stream_with :full_read
        queue :execution
        scheduler_cron "* * * * *"
        max_attempts 3
        use_tenant_from_record? true
        actor_persister :none
        default_actor AshEnterprise.Platform.SystemActor.oban()
        worker_module_name AshEnterprise.Execution.Invocation.ExecuteWorker
        scheduler_module_name AshEnterprise.Execution.Invocation.ExecuteScheduler
      end

      # A person decided the row's approval, or it expired undecided: apply it. The
      # sweep is the only path, so a crash between the decision and its application
      # heals on the next run. The update keeps ash_oban's default lock on the row.
      trigger :apply_decision do
        action :apply_decision

        where expr(
                status == :awaiting_approval and
                  (exists(approval_task, status in [:completed, :cancelled]) or
                     approval_expires_at <= now())
              )

        read_action :read
        stream_with :full_read
        queue :execution
        scheduler_cron "* * * * *"
        max_attempts 3
        use_tenant_from_record? true
        actor_persister :none
        default_actor AshEnterprise.Platform.SystemActor.oban()
        worker_module_name AshEnterprise.Execution.Invocation.ApplyDecisionWorker
        scheduler_module_name AshEnterprise.Execution.Invocation.ApplyDecisionScheduler
      end

      # Rows no job is coming for: a worker died holding the lease, a dispatch deadline
      # passed, or the outcome is unknown and nobody has been asked yet.
      # `mark_outcome_unknown` enqueues it in its own transaction; the scheduler is the
      # sweep for the other two, which nothing enqueues. The action calls out (a
      # `reconcile_with` lookup), so it holds no transaction.
      trigger :reconcile do
        action :reconcile

        where expr(
                (status == :executing and lease_expires_at <= now()) or
                  (status == :dispatched and deadline_at <= now()) or
                  (status == :outcome_unknown and is_nil(resolution_requested_at))
              )

        read_action :read
        stream_with :full_read
        queue :execution
        scheduler_cron "* * * * *"
        max_attempts 3
        use_tenant_from_record? true
        actor_persister :none
        default_actor AshEnterprise.Platform.SystemActor.oban()
        worker_module_name AshEnterprise.Execution.Invocation.ReconcileWorker
        scheduler_module_name AshEnterprise.Execution.Invocation.ReconcileScheduler
      end

      # A person settled an unknown outcome: apply it. The sweep is the only path, so a
      # crash between the task's decision and its application heals on the next run.
      trigger :apply_resolution do
        action :apply_resolution

        where expr(
                status == :outcome_unknown and not is_nil(resolution_requested_at) and
                  exists(resolution_task, status == :completed)
              )

        read_action :read
        queue :execution
        scheduler_cron "* * * * *"
        max_attempts 3
        use_tenant_from_record? true
        actor_persister :none
        default_actor AshEnterprise.Platform.SystemActor.oban()
        worker_module_name AshEnterprise.Execution.Invocation.ApplyResolutionWorker
        scheduler_module_name AshEnterprise.Execution.Invocation.ApplyResolutionScheduler
      end

      # A person answered an agent's question, or its task was cancelled: complete the
      # dispatched row from the task. The sweep is the only path, so a crash between the
      # answer and its collection heals on the next run. While nobody has answered,
      # nothing matches, and no job exists for the row or its run.
      trigger :collect_input do
        action :collect_input

        where expr(
                status == :dispatched and effect_system == "human_input" and
                  exists(input_task, status in [:completed, :cancelled])
              )

        read_action :read
        queue :execution
        scheduler_cron "* * * * *"
        max_attempts 3
        use_tenant_from_record? true
        actor_persister :none
        default_actor AshEnterprise.Platform.SystemActor.oban()
        worker_module_name AshEnterprise.Execution.Invocation.CollectInputWorker
        scheduler_module_name AshEnterprise.Execution.Invocation.CollectInputScheduler
      end
    end
  end

  calculations do
    calculate :recorded?, :boolean, expr(erasure_scope.status == :active) do
      public? true

      description "False once the erasure scope is shredded: `args` and `result` then read as erased."
    end
  end

  relationships do
    belongs_to :erasure_scope, AshEnterprise.Erasure.Scope do
      public? true
      description "The erasure scope `args` and `result` are sealed under."
    end

    # The approval task `request` opened, under the static key: one per row.
    has_one :approval_task, AshEnterprise.Bpmn.HumanTask do
      public? true
      from_many? true
      destination_attribute :subject_id
      sort inserted_at: :desc

      filter expr(
               node_id == "invocation.approval" and
                 subject_type == "Elixir.AshEnterprise.Execution.Invocation"
             )

      description "The task a person approves or rejects this row with."
    end

    # The task opened by the latest `request_resolution`. A retried row that becomes
    # unknown again asks again, and only the task opened since then counts.
    has_one :resolution_task, AshEnterprise.Bpmn.HumanTask do
      public? true
      from_many? true
      destination_attribute :subject_id
      sort inserted_at: :desc

      filter expr(
               node_id == "invocation.resolution" and
                 subject_type == "Elixir.AshEnterprise.Execution.Invocation" and
                 inserted_at >= parent(resolution_requested_at)
             )

      description "The task a person settles this row's unknown outcome with."
    end

    # The question a `HumanInput.request` call handed on, under the static key: one per row.
    has_one :input_task, AshEnterprise.Bpmn.HumanTask do
      public? true
      from_many? true
      destination_attribute :subject_id
      sort inserted_at: :desc

      filter expr(
               node_id == "invocation.input" and
                 subject_type == "Elixir.AshEnterprise.Execution.Invocation"
             )

      description "The task the person the run acts for answers this row's question with."
    end
  end
end
