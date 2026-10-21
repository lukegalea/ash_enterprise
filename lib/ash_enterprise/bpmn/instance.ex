defmodule AshEnterprise.Bpmn.Instance do
  @moduledoc """
  One run of a process, pinned to the definition version it started on.

  Audited: an instance is the record that a process ran at all, and it carries the correlation
  id that joins it to whatever request or event started it.
  """

  use AshBpmn.Resources.Instance,
    domain: AshEnterprise.Bpmn,
    repo: AshEnterprise.Repo,
    table: "bpmn_instances",
    definition: AshEnterprise.Bpmn.Definition,
    base: AshEnterprise.Platform.Resource,
    base_opts: [
      ownership: :organization_owned,
      # `running -> completed | failed | cancelled` is the instance's own state machine.
      lifecycle?: false,
      audit?: true,
      archival?: false,
      # Someone asked to decide one of the run's steps may read the run — its
      # flight view — without a role grant (ActorContext `task_instance_ids`).
      extra_grants: [{AshEnterprise.Security.Checks.TaskInstance, field: :id}]
    ]

  # --- the flight views (`/app/flights`, AshEnterprise.Process.FlightDiagram) ---
  #
  # What a person reads about a run beside its diagram. Each is read as the
  # reader: the subject under its own policies, the tokens under the run's.

  calculations do
    calculate :subject_label,
              :string,
              {AshEnterprise.Bpmn.Calculations.SubjectSummary, field: :label} do
      public? true
      description "What the run is about: `Morning brief · Mon 12 Oct`, or the subject's kind."
    end

    calculate :process_name, :string, AshEnterprise.Bpmn.Calculations.ProcessName do
      public? true
      description "The process the run executes, with the version it pinned."
    end

    calculate :stage_label, :string, AshEnterprise.Bpmn.Calculations.StageLabel do
      public? true
      description "Where the run stands: the steps its live tokens are on, or how it ended."
    end

    calculate :started_label,
              :string,
              {AshEnterprise.Platform.Calculations.LocalStamp,
               field: :inserted_at, relative?: true} do
      public? true
      description "When the run started, on the operator's wall clock."
    end
  end

  actions do
    read :running_now do
      description "Running process instances the reader may see, newest first."
      filter expr(status == :running)
      prepare build(sort: [inserted_at: :desc, id: :desc])
    end

    read :running_process do
      description "Running instances of one process key (any version), newest first."

      argument :process, :string do
        allow_nil? false
        description "The process key, `morning.brief`."
      end

      filter expr(status == :running)
      prepare AshEnterprise.Bpmn.Preparations.OfProcess
      prepare build(sort: [inserted_at: :desc, id: :desc])
    end

    # The same, fixed to the two processes with a flight view of their own (a
    # surface table names a read action, not its arguments).
    read :running_briefs do
      description "Running `morning.brief` instances, newest first."
      filter expr(status == :running)
      prepare {AshEnterprise.Bpmn.Preparations.OfProcess, process: "morning.brief"}
      prepare build(sort: [inserted_at: :desc, id: :desc])
    end

    read :running_steward_reviews do
      description "Running `mdm.steward_review` instances, newest first."
      filter expr(status == :running)
      prepare {AshEnterprise.Bpmn.Preparations.OfProcess, process: "mdm.steward_review"}
      prepare build(sort: [inserted_at: :desc, id: :desc])
    end
  end
end
