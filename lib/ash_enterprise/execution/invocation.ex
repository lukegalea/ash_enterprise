defmodule AshEnterprise.Execution.Invocation do
  @moduledoc """
  One governed invocation (ADR 0055): the `AshAgent.Invocation` fragment on the platform
  base, in table `exec_invocations`.

  ## What the fragment brings

  The attributes, the lifecycle (`requested → awaiting_approval → ready → executing →
  succeeded | failed`, plus `rejected`, `stale`, `cancelled`; terminal states never
  change) and the actions: `invoke`, `request`, `claim`, `succeed`, `fail`,
  `apply_decision`, `request_cancel` and `execute`. See the fragment's docs.

  ## What this resource adds

    * **Tenancy and ownership.** Tenant-scoped and user-owned: `request` stamps the
      requesting person as `owner_id`. Audited (every transition is an event), not
      temporal (ADR 0049 keeps temporal for validity; this is a state machine with
      history), no soft delete, and the fragment's state machine instead of the base's
      lifecycle (`lifecycle?: false`, spike S9).
    * **Who may do what.** `invoke` and `request` are self-service (ADR 0052): any active
      member may ask on their own behalf, and `request` creates only rows they own.
      `claim`, `succeed`, `fail`, `apply_decision` and `execute` are machinery-only (ADR
      0059): only the `oban` system actor reaches them, and no grant does. Reads and
      `request_cancel` go through the grant union.
    * **The parent.** A request may name only a parent its requester owns
      (`AshEnterprise.Execution.Validations.OwnsParent`), so calling `request` directly
      gains nothing over `invoke`.
    * **Sealing.** `args` and `result` are sealed under an erasure scope (ADR 0024): the
      subject's when the target acts on a record that has one, otherwise the requester's
      own (`AshEnterprise.Execution.Changes.SealingScope`). `args_digest` is an HMAC under
      a key derived from that scope's key (`AshEnterprise.Execution.DigestKey`), so a
      shred makes both unreadable and the digest unrecomputable. No plaintext copy is
      derived (spike S2).
    * **Identity.** `AshEnterprise.Execution.Identity` names a person as the principal and
      rebuilds their `ActorContext` from grant rows at every claim.
    * **The `:execute` trigger.** `request` and `apply_decision` enqueue it for every
      ready row in their own transaction; its scheduler sweeps any ready row whose job
      was lost. It takes the tenant from the row, persists no actor, and runs a generic
      action that holds no transaction (spike S5).
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Execution,
    ownership: :user_owned,
    lifecycle?: false,
    archival?: false,
    self_service: [:invoke, :request],
    machinery_only: [:claim, :succeed, :fail, :apply_decision, :execute],
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
    end
  end

  relationships do
    belongs_to :erasure_scope, AshEnterprise.Erasure.Scope do
      public? true
      description "The erasure scope `args` and `result` are sealed under."
    end
  end
end
