defmodule AshEnterprise.Agents.ToolInvocation do
  @moduledoc """
  The approval-gated unit (dogfood §6, ADR 0015): one privileged tool the
  agent process asked to use, exactly bound to a human decision.

  Lifecycle: the bridge records `:pending` when it sees a tool request and
  pauses the run; `AshEnterprise.Agents.ToolGate.approve_invocation/2` /
  `reject_invocation/2` are the only paths to `:approved` / `:rejected` —
  both are person acts on that one row, and both order the bridge to write
  the matching `tool_response` to the port. `:completed` (with `result`) is
  set by the bridge when the run reports the tool's outcome. The transition
  validations make the gates real: a pending invocation is the only thing
  that can be approved, an approved one the only thing that can complete.

  `lifecycle?: false`/`archival?: false`: `status` is the lifecycle; these
  rows are the audit trail of what an agent asked and what a human answered.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Agents,
    lifecycle?: false,
    archival?: false

  postgres do
    table "agent_tool_invocations"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :tool_name, :string do
      allow_nil? false
      public? true
      constraints max_length: 256

      description "The tool as the agent named it."
    end

    attribute :input, :map do
      allow_nil? false
      public? true
      default %{}

      description "The exact arguments the agent requested, verbatim."
    end

    attribute :request_id, :string do
      public? true
      constraints max_length: 256

      description """
      The request id the agent protocol gave this invocation, echoed back in
      the tool_response. Absent when the request line carried no id, in which
      case the row id identifies the exchange.
      """
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:pending, :approved, :rejected, :completed]
      default :pending

      description "pending until a person decides; completed when the run reports the outcome."
    end

    attribute :result, :map do
      public? true

      description "The tool's outcome as reported by the run. Set together with :completed."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :run, AshEnterprise.Agents.AgentRun do
      allow_nil? false
      public? true

      description "The run that requested this tool."
    end
  end

  actions do
    defaults [:read]

    read :for_run do
      description "Every invocation a run asked for, oldest first."

      argument :run_id, :uuid, allow_nil?: false

      filter expr(run_id == ^arg(:run_id))
      prepare build(sort: [inserted_at: :asc])
    end

    create :record do
      description "Records one tool request as pending. Bridge-internal."

      # Owner inherited from the run, for the same reason as messages.
      accept [:run_id, :tool_name, :input, :request_id, :owner_id, :owning_user_id]
    end

    update :approve do
      description "The person gate opens: exactly this invocation may run."

      accept []

      validate attribute_equals(:status, :pending) do
        message "only a pending invocation can be approved"
      end

      change set_attribute(:status, :approved)
    end

    update :reject do
      description "The person gate stays shut. The run resumes; the tool never executes."

      accept []

      validate attribute_equals(:status, :pending) do
        message "only a pending invocation can be rejected"
      end

      change set_attribute(:status, :rejected)
    end

    update :complete do
      description "The bridge records the tool's reported outcome. Bridge-internal."

      accept [:result]

      validate attribute_equals(:status, :approved) do
        message "only an approved invocation can complete"
      end

      change set_attribute(:status, :completed)
    end
  end

  code_interface do
    define :record, action: :record
    define :by_id, action: :read, get_by: [:id]
    define :for_run, action: :for_run, args: [:run_id]
    define :approve, action: :approve
    define :reject, action: :reject
    define :complete, action: :complete, args: [:result]
  end
end
