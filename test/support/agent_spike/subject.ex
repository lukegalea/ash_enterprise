defmodule AshEnterprise.AgentSpike.Subject do
  @moduledoc """
  A test-only view of an existing platform table, for the proof spikes that
  need a trigger, a calculated `where` and an approval subject on a real
  `AshEnterprise.Platform.Resource` (S5, S6).

  ## Why it reads `canonical_tasks`

  The spikes must not add schema. A resource with the same platform options
  as `AshEnterprise.Canonical.Task` (user-owned, tenant-scoped, no platform
  lifecycle, no soft delete, audited) declares a subset of that table's
  columns, so every system attribute the base adds already exists there.
  `migrate? false` keeps it out of codegen, and the domain is never
  registered, so nothing outside `:test` sees it. Rows are created through
  the real resource and then worked through this one.

  The mapping it uses: `status` `:proposed` stands for "awaiting approval"
  and `:open` for "ready"; `plan` `:today` for "has a step to take".

  ## What it carries

    * `:request_approval`: an update that moves the row to awaiting approval
      and requests one through `AshEnterprise.AgentSpike.RequestApproval`,
      which computes the approval's options at runtime and delegates to
      `AshBpmn.Changes.RequireApproval`.
    * `:apply_decision`: a trigger on a calculated `where` (the approval task
      for this row was completed as approved) whose update checks the
      decision and moves the row to ready.
    * `:step`: a trigger on a calculated `where` whose action is a generic
      action (generic actions run without a transaction by default) that
      claims the row with a filtered update.

  Both triggers take the tenant from the row (`use_tenant_from_record?`),
  never persist an actor (`actor_persister :none`) and run as the `:oban`
  system actor, as the plan's rules for every trigger require.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.AgentSpike,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false,
    lineage?: false,
    extra_extensions: [AshOban]

  require Ash.Expr

  postgres do
    table "canonical_tasks"
    repo AshEnterprise.Repo
    migrate? false
  end

  oban do
    triggers do
      trigger :apply_decision do
        action :apply_decision
        where expr(status == :proposed and decision_approved)
        queue :agent_spike
        scheduler_cron "* * * * *"
        max_attempts 1
        use_tenant_from_record? true
        actor_persister :none
        default_actor AshEnterprise.Platform.SystemActor.oban()
        worker_module_name AshEnterprise.AgentSpike.Subject.ApplyDecisionWorker
        scheduler_module_name AshEnterprise.AgentSpike.Subject.ApplyDecisionScheduler
      end

      trigger :step do
        action :step
        where expr(needs_step)
        queue :agent_spike
        scheduler_cron "* * * * *"
        max_attempts 1
        use_tenant_from_record? true
        actor_persister :none
        default_actor AshEnterprise.Platform.SystemActor.oban()
        worker_module_name AshEnterprise.AgentSpike.Subject.StepWorker
        scheduler_module_name AshEnterprise.AgentSpike.Subject.StepScheduler
      end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string, allow_nil?: false, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:proposed, :open, :done, :cancelled]
    end

    attribute :plan, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:inbox, :today, :later]
    end

    attribute :source, :string, allow_nil?: false, public?: true
    update_timestamp :updated_at
  end

  calculations do
    calculate :needs_step, :boolean, expr(status == :open and plan == :today) do
      public? true
    end

    calculate :decision_approved,
              :boolean,
              expr(
                exists(
                  AshEnterprise.Bpmn.HumanTask,
                  subject_type == "Elixir.AshEnterprise.AgentSpike.Subject" and
                    subject_id == parent(id) and node_id == "invocation.approval" and
                    status == :completed and outcome == "approved"
                )
              ) do
      public? true
    end
  end

  actions do
    defaults [:read]

    update :request_approval do
      accept []
      require_atomic? false
      validate attribute_equals(:status, :open), message: "only a ready row can request approval"
      change set_attribute(:status, :proposed)
      change AshEnterprise.AgentSpike.RequestApproval
    end

    update :apply_decision do
      accept []
      require_atomic? false
      change AshEnterprise.AgentSpike.ApplyDecision
      change set_attribute(:status, :open)
    end

    update :set_plan do
      accept [:plan]
      require_atomic? false
    end

    update :claim_step do
      accept []
      require_atomic? false
      change filter(expr(status == :open and plan == :today))
      change set_attribute(:plan, :later)
    end

    action :step, :atom do
      constraints one_of: [:stepped, :skipped]
      argument :primary_key, :map, allow_nil?: false
      run AshEnterprise.AgentSpike.Step
    end
  end
end
