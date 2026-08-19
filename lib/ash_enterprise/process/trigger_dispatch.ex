defmodule AshEnterprise.Process.TriggerDispatch do
  @moduledoc """
  What the dispatcher did with one audit event, for one trigger.

  Append-only, one row per `(trigger_id, event_id)`, written **in the same transaction as the
  instance start**.

  ## Two jobs, and the second is the valuable one

  It makes duplicate starts *provably* impossible under a partial failure. The cursor already
  makes them impossible in the ordinary case — see `AshEnterprise.Process.TriggerCursor` — but
  a sweep that crashes mid-batch replays it, and the identity here turns the replay into a
  `:skipped` row rather than a second process.

  More usefully, it answers **"why did this process start?"** — which is the question anyone
  asks first when a process appears that nobody remembers requesting, and which nothing else in
  the system can answer. It records the trigger and its version, the event, the decision and
  the rule that fired, and the instance that resulted.

  It is the trigger layer's equivalent of `AshEnterprise.Bpmn.ProcessEvent`: it records what
  the audit log structurally cannot, and it **never duplicates a row change**. The instance it
  started is already an audited create; this row says why.

  ## Failures are rows, not exceptions

  A trigger that could not dispatch records `:failed` with a reason and the cursor advances
  past it. That is deliberate: a broken trigger must never wedge the audit stream for a tenant,
  and a failure that is queryable is one somebody can find.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Process,
    ownership: :organization_owned,
    lifecycle?: false,
    audit?: false,
    archival?: false

  postgres do
    table "process_trigger_dispatches"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :event_id, :uuid do
      allow_nil? false
      public? true
      description "The audit event this dispatch was decided from."
    end

    attribute :event_sequence, :integer do
      allow_nil? false
      public? true

      description "Its position in the tenant's chain, so a dispatch can be located without a join."
    end

    attribute :status, :atom do
      allow_nil? false
      constraints one_of: [:started, :skipped, :failed]
      public? true
    end

    attribute :reason, :atom do
      constraints one_of: [
                    :guard_false,
                    :guard_error,
                    :decision_error,
                    :no_rule_fired,
                    :no_published_definition,
                    :fan_out_exceeded,
                    :already_dispatched,
                    :self_trigger_refused
                  ]

      public? true
      description "Why a dispatch was skipped or failed. Nil when it started."
    end

    attribute :process_key, :string, public?: true
    attribute :decision_key, :string, public?: true

    attribute :fired_rule, :string do
      public? true
      description "Which rule of the routing decision matched, when the engine can say."
    end

    attribute :instance_id, :uuid do
      public? true
      description "The process instance this started. Nil unless status is :started."
    end

    attribute :error, :map do
      public? true
      description "Detail for a :failed dispatch, as data rather than a log line."
    end

    attribute :correlation_id, :string do
      public? true
      description "Carried from the originating event, so the process joins its cause."
    end

    attribute :depth, :integer do
      allow_nil? false
      default 0
      public? true

      description """
      How many trigger hops led here. Zero for an event a person caused.

      A process start writes audited rows, and audited rows are trigger inputs, so a cycle is
      structurally possible. `AshEnterprise.Process.Trigger` refuses to match the process and
      decision domains, which closes the direct path; this bounds any indirect one, so a cycle
      is *bounded* rather than merely improbable.
      """
    end
  end

  relationships do
    belongs_to :trigger, AshEnterprise.Process.Trigger do
      allow_nil? false
      public? true
    end
  end

  identities do
    # The constraint that makes a replayed batch idempotent. Per tenant automatically.
    identity :once_per_event, [:trigger_id, :event_id]
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :trigger_id,
        :event_id,
        :event_sequence,
        :status,
        :reason,
        :process_key,
        :decision_key,
        :fired_rule,
        :instance_id,
        :error,
        :correlation_id,
        :depth
      ]
    end

    read :for_event do
      argument :event_id, :uuid, allow_nil?: false
      filter expr(event_id == ^arg(:event_id))
    end
  end

  code_interface do
    define :create
    define :for_event, args: [:event_id]
  end
end
