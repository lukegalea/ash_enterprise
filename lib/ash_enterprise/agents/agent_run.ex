defmodule AshEnterprise.Agents.AgentRun do
  @moduledoc """
  One requested unit of coding-agent work (dogfood §6): a prompt handed to the
  OMP process of a session, the messages it streamed back, and the tool
  invocations it asked for.

  The status machine is small and terminal states are terminal: `:running`
  until the bridge observes the process exit (or an operator cancels), then
  exactly one of `:completed` / `:failed` / `:cancelled`. `finished_at` is set
  by the same action that sets the terminal status, so a run can never be
  finished without a timestamp or timestamped while still running.

  `lifecycle?: false`/`archival?: false` for the same reasons as the session:
  `status` is the lifecycle; terminal rows are history, not soft-deleted data.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Agents,
    lifecycle?: false,
    archival?: false

  postgres do
    table "agent_runs"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :prompt, :string do
      allow_nil? false
      public? true

      description "The initial message handed to the agent process."
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:running, :completed, :failed, :cancelled]
      default :running

      description "running until the bridge observes a process exit or a cancellation lands."
    end

    attribute :started_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the run action was taken."
    end

    attribute :finished_at, :utc_datetime_usec do
      public? true
      description "When the run reached a terminal status. Set together with the status."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :session, AshEnterprise.Agents.AgentSession do
      allow_nil? false
      public? true

      description "The session whose workspace this run executes in."
    end
  end

  actions do
    defaults [:read]

    create :start do
      description """
      Requests one unit of work. The bridge (AshEnterprise.Agents.OmpSession)
      turns this row into an `omp --mode rpc` process in the session's
      workspace; it, not callers, owns every transition away from :running.
      """

      accept [:session_id, :prompt]

      # The run belongs to whoever started it; the transcript rows it
      # produces inherit this owner (the bridge copies it down).
      change set_attribute(:owner_id, actor(:id))
      change set_attribute(:owner_type, :user)
      change set_attribute(:owning_user_id, actor(:id))

      change AshEnterprise.Agents.Changes.SpawnOmpProcess
      change set_attribute(:started_at, &DateTime.utc_now/0)
    end

    update :cancel do
      description "Operator cancellation. The bridge stops the process; the run keeps its transcript."

      accept []

      validate attribute_equals(:status, :running) do
        message "only a running run can be cancelled"
      end

      change set_attribute(:status, :cancelled)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      require_atomic? false
    end

    update :complete do
      description "The bridge records a clean process exit. Bridge-internal."

      accept []

      validate attribute_equals(:status, :running) do
        message "only a running run can complete"
      end

      change set_attribute(:status, :completed)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      require_atomic? false
    end

    update :fail do
      description "The bridge records a failure: nonzero exit or an unstartable process. Bridge-internal."

      accept []

      validate attribute_equals(:status, :running) do
        message "only a running run can fail"
      end

      change set_attribute(:status, :failed)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      require_atomic? false
    end
  end

  code_interface do
    define :start, action: :start, args: [:session_id, :prompt]
    define :by_id, action: :read, get_by: [:id]
    define :read, action: :read
    define :cancel, action: :cancel
    define :complete, action: :complete
    define :fail, action: :fail
  end
end
