defmodule AshEnterpriseWeb.A2ui.LineageUI do
  @moduledoc """
  Lineage — what ran, what it read and wrote, and what broke
  (`AshEnterprise.Lineage`).

    * **The graph.** A live diagram of jobs and the datasets they read and
      write, for a time window and optionally one job's neighbourhood
      (`AshEnterprise.Lineage.Diagram`). Markers are runs: a failed run is
      red, a running one pulses, a job's latest completed run is muted. Each
      opens its run.
    * **Runs.** One row per operation (a sync step, a request), newest first,
      with its state; narrowed by the job picker to the runs that job
      started.
    * **A run.** Its detail, the job runs inside it (what each read and
      wrote, and why it failed), and the audit entries it wrote — the same
      correlation id — each opening on the Audit trail.

  Read-only. Everything is read as the signed-in person in their tenant,
  under their lineage read grant. Served at `/app/lineage`
  (`AshEnterpriseWeb.LineageLive`) and, as the `lineage` prompt, over ACP.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Lineage.Run
    surface_id "lineage"
    title "Lineage"
    record_label "run"
    spec_version "1.0"

    context :window do
      resource AshEnterprise.Lineage.Window
      label "Window"
      option_label :label
      option_search [:label]
    end

    context :job do
      resource AshEnterprise.Lineage.Job
      label "Job"
      option_label :label
      option_search [:label]
      option_limit 25
    end

    context :run do
      resource AshEnterprise.Lineage.Run
      picker false
    end

    diagram :graph do
      label "Lineage graph"

      description "Jobs and the datasets they read and write. A red marker is a failed run, " <>
                    "a pulsing one is still running. Pick a window or a job to narrow it."

      source AshEnterprise.Lineage.Diagram
    end

    query :runs do
      sortable [:last_event_at, :first_event_at]
      filters [:state]
      range_filters [:last_event_at]
      default_sort last_event_at: :desc
      page_size 25
      max_page_size 100
    end

    query :job_runs do
      sortable [:started_at]
      default_sort started_at: :asc
      page_size 25
      max_page_size 100
    end

    query :audit do
      sortable [:occurred_at]
      default_sort occurred_at: :asc
      page_size 25
      max_page_size 100
    end

    component :table do
      fields [
        :label,
        :state,
        :first_event_at,
        :last_event_at,
        :job_count,
        :event_count,
        :error_message
      ]

      read_action :read
      query :runs
      context_filter job_id: :job
      select_context :run

      row_layout do
        title :label
        badge :state
        badge_text running: "Running", complete: "Complete", failed: "Failed"
        badge_tones running: :info, complete: :success, failed: :danger
        meta [:first_event_at, :last_event_at, :job_count, :event_count, :error_message]
        columns 3
      end
    end

    component :detail, :run_detail do
      context :run

      fields [
        :label,
        :state,
        :first_event_at,
        :last_event_at,
        :job_count,
        :event_count,
        :error_message,
        :account,
        :correlation_id
      ]
    end

    component :table, :job_runs do
      resource AshEnterprise.Lineage.JobRun

      fields [
        :job_label,
        :state,
        :started_at,
        :ended_at,
        :event_count,
        :reads,
        :writes,
        :error_message
      ]

      query :job_runs
      context_filter lineage_run_id: :run
      require_context [:run]

      row_layout do
        title :job_label
        badge :state
        badge_text running: "Running", complete: "Complete", failed: "Failed"
        badge_tones running: :info, complete: :success, failed: :danger
        meta [:started_at, :ended_at, :event_count, :reads, :writes, :error_message]
        columns 3
      end
    end

    component :table, :audit_entries do
      resource AshEnterprise.Audit.EventLog
      fields [:occurred_at, :resource, :action, :record_id]
      query :audit
      context_filter correlation_id: :run
      require_context [:run]
    end

    field :label do
      label "Run"
    end

    field :state do
      label "State"
    end

    field :first_event_at do
      label "Started"
    end

    field :last_event_at do
      label "Last event"
    end

    field :job_count do
      label "Jobs"
    end

    field :event_count do
      label "Events"
    end

    field :error_message do
      label "Error"
    end

    field :correlation_id do
      label "Correlation id"
    end

    # The sync this run is, when it is one; shown only to a reader who may
    # read that linked account.
    field :account do
      label "Linked account"
      link :linked_account
      link_label :label
    end

    field :job_label do
      label "Job"
    end

    field :started_at do
      label "Started"
    end

    field :ended_at do
      label "Ended"
    end

    field :reads do
      label "Reads"
    end

    field :writes do
      label "Writes"
    end

    # Opens the entry on the Audit trail, which links back here.
    field :occurred_at do
      label "When"
      link {:audit, :id}
    end

    field :resource do
      label "Resource"
    end

    field :action do
      label "Action"
    end

    field :record_id do
      label "Record"
    end
  end
end
