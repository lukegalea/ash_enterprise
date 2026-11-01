defmodule AshEnterprise.Quality.SuiteRun do
  @moduledoc """
  One run of a published suite against a candidate agent (ADR 0058), in table
  `quality_suite_runs`: `running → finished`.

  ## Starting

  `start` pins the candidate, the agent's latest published version in the tenant
  (`candidate_digest` is its `content_hash`), and starts one agent run per case in the
  same transaction (`AshEnterprise.Quality.Changes.StartCases`), as the person starting
  the suite run, who needs the agent's start grant. Each case's run is an ordinary
  `AshEnterprise.Execution.Run`, keyed `quality:<suite run id>:<case id>:<epoch>`, with
  `origin: :eval`, the case's `input` and its `fixtures`, and a mode that causes no
  effects:

    * `:offline` runs the cases with `mode: :eval`;
    * `:shadow` runs them with `mode: :shadow`: the same cases, run beside live work to
      compare a candidate with what is live, with no effect either.

  A run that is not live executes as the `evaluator` automation principal
  (`AshEnterprise.Execution.Identity`), whose roles exist only in the tenant evaluations
  run in, and every tool call that is not a read is answered from the case's fixtures
  without running (`AshEnterprise.Execution.Invocation`). Nothing is rolled back to
  undo an effect: there is none.

  ## Finishing

  Once no case's run is queued, running or waiting on its tools (`settled`), the `:finish` trigger scores them
  (`AshEnterprise.Quality.Changes.Finish`): one `AshEnterprise.Quality.CaseResult` per
  case and epoch, and a `summary` with quality and safety in separate lanes. Its sweep
  runs every minute; nothing enqueues it sooner.

  User-owned and audited: the person who started it owns it. Starting is the
  `quality.run` privilege of ADR 0058 (create on this resource), reading it
  `quality.read`; `finish` is the job runner's alone.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Quality,
    ownership: :user_owned,
    lifecycle?: false,
    archival?: false,
    machinery_only: [:finish],
    extra_extensions: [AshStateMachine, AshOban]

  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Quality.Changes

  postgres do
    table "quality_suite_runs"
    repo AshEnterprise.Repo

    references do
      reference :suite, on_delete: :restrict
    end
  end

  state_machine do
    state_attribute :status
    initial_states [:running]
    default_initial_state :running

    transitions do
      transition :finish, from: :running, to: :finished
    end
  end

  oban do
    triggers do
      # A suite run whose cases have all finished. Only the sweep finds them.
      trigger :finish do
        action :finish
        where expr(status == :running and settled)
        read_action :read
        queue :quality
        scheduler_cron "* * * * *"
        max_attempts 3
        use_tenant_from_record? true
        actor_persister :none
        default_actor SystemActor.oban()
        worker_module_name AshEnterprise.Quality.SuiteRun.FinishWorker
        scheduler_module_name AshEnterprise.Quality.SuiteRun.FinishScheduler
      end
    end
  end

  actions do
    defaults [:read]

    create :start do
      description "Run a published suite against an agent's latest published version, with no effects."
      accept [:suite_id, :agent_key, :mode]

      change set_attribute(:owner_id, actor(:id))
      change Changes.StartCases
    end

    update :finish do
      description "Score a suite run whose cases have all finished."
      accept []
      require_atomic? false

      change transition_state(:finished)
      change Changes.Finish
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :agent_key, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
      description "The agent the suite is run against."
    end

    attribute :agent_version_id, :uuid do
      public? true
      description "The candidate: the agent version pinned when the suite run started."
    end

    attribute :candidate_digest, :string do
      public? true
      description "The candidate's `content_hash`."
    end

    attribute :suite_content_hash, :string do
      public? true
      description "The suite's `content_hash`: exactly the cases this run measured."
    end

    attribute :mode, :atom do
      allow_nil? false
      public? true
      default :offline
      constraints one_of: [:offline, :shadow]
    end

    attribute :summary, :map do
      public? true
      description "The scores, with quality and safety in separate lanes, set when it finishes."
    end

    attribute :eval_log_version, :integer do
      allow_nil? false
      public? true
      default 2
      description "The Inspect EvalLog version results export as."
    end

    attribute :finished_at, :utc_datetime_usec, public?: true
  end

  relationships do
    belongs_to :suite, AshEnterprise.Quality.Suite do
      allow_nil? false
      public? true
      attribute_writable? true
    end

    has_many :case_results, AshEnterprise.Quality.CaseResult do
      public? true
    end
  end

  calculations do
    calculate :settled,
              :boolean,
              expr(
                not exists(
                  AshEnterprise.Execution.Run,
                  origin == :eval and contains(run_key, "quality:" <> type(parent(id), :string)) and
                    (status in [:queued, :running] or
                       (status == :waiting and blocked_on == :tools))
                )
              ) do
      public? true
      description "Whether every case's agent run has finished."
    end
  end

  @doc "The run key of `case_id`'s run in the suite run `id`, at `epoch`."
  @spec run_key(Ash.UUID.t(), String.t(), pos_integer()) :: String.t()
  def run_key(id, case_id, epoch), do: "quality:#{id}:#{case_id}:#{epoch}"
end
