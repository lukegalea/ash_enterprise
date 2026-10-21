defmodule AshEnterprise.Lineage.Run do
  @moduledoc """
  One operation: every lineage event that shared a correlation id. A Gmail
  sync step is one run — the sync job, its landings into
  `ingestion_source_objects`, its projection and the canonical rows it
  wrote — and so is one person's request that wrote several tables.

  **Its id is the correlation id**, which is also the audit log's
  `correlation_id` (`AshEnterprise.Audit.EventLog`): `audit_entries` is a
  plain relationship, and an audit entry's `lineage_run` is its correlation
  id read as a run. (A run under a derived id — one tenant's events inside
  another tenant's correlation, see `AshEnterprise.Lineage.Recorder` — keeps
  the correlation in `correlation_id`, and finds its audit entries through
  that.)

  State is derived from the run's job runs: failed if any failed, running
  if any is still running, complete otherwise.

  Written only by the lineage store; read under the reader's grants, inside
  the reader's tenant. Opt-outs as `AshEnterprise.Lineage.Job`'s.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Lineage,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    lineage?: false,
    policies?: false

  postgres do
    table "lineage_runs"
    repo AshEnterprise.Repo

    references do
      reference :job, on_delete: :nilify
      # A run outlives the sync that made it only until retention deletes
      # it; an unlinked or erased account must not be blocked by its runs.
      reference :linked_account, ignore?: true
    end

    custom_indexes do
      index [:organization_id, :last_event_at]
      index [:correlation_id]
      index [:linked_account_id, :last_event_at]
    end
  end

  attributes do
    attribute :id, :uuid do
      primary_key? true
      allow_nil? false
      public? true

      description "The correlation id (or, for a tenant's events in another's correlation, one derived from it)."
    end

    attribute :correlation_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :job_label, :string do
      allow_nil? false
      public? true
      description ~S(The job that started the run, e.g. "ingestion.gmail.sync".)
    end

    attribute :first_event_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :last_event_at, :utc_datetime_usec, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :job, AshEnterprise.Lineage.Job do
      public? true
      attribute_public? true
      description "The job that started the run."
    end

    belongs_to :linked_account, AshEnterprise.Integration.LinkedAccount do
      public? true
      attribute_public? true
      domain AshEnterprise.Integration
      description "The linked account whose sync this run is, when it is one."
    end

    has_many :job_runs, AshEnterprise.Lineage.JobRun do
      public? true
      destination_attribute :lineage_run_id
    end

    has_many :audit_entries, AshEnterprise.Audit.EventLog do
      public? true
      domain AshEnterprise.Audit
      source_attribute :correlation_id
      destination_attribute :correlation_id
    end
  end

  aggregates do
    exists :failed?, :job_runs do
      public? true
      filter expr(state == :failed)
    end

    exists :running?, :job_runs do
      public? true
      filter expr(state == :running)
    end

    count :job_count, :job_runs, public?: true

    sum :event_count, :job_runs, :event_count, public?: true

    first :error_message, :job_runs, :error_message do
      public? true
      filter expr(state == :failed)
      sort last_event_at: :desc
    end
  end

  calculations do
    calculate :state,
              :atom,
              expr(
                cond do
                  failed? -> :failed
                  running? -> :running
                  true -> :complete
                end
              ) do
      public? true
      constraints one_of: [:running, :complete, :failed]
    end

    calculate :label, :string, expr(job_label) do
      public? true
    end
  end

  actions do
    defaults [:read]

    create :record do
      description "The lineage store's upsert. Nothing else writes runs."
      accept :*
      upsert? true
      upsert_fields [:job_id, :job_label, :linked_account_id, :first_event_at, :last_event_at]
    end

    destroy :prune do
      description "Retention: deletes runs (and, by foreign key, their job runs) past the window."
    end
  end

  policies do
    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end
  end
end
