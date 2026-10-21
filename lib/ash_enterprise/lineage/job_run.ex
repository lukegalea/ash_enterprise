defmodule AshEnterprise.Lineage.JobRun do
  @moduledoc """
  One OpenLineage run: one job inside one operation (`AshEnterprise.Lineage.Run`),
  keyed by the event's `run.runId`. The lineage graph's edges: the datasets
  it read and wrote, and its state — running (a START, no end yet),
  complete or failed, with the FAIL event's error message.

  A resource job emits one COMPLETE per row written, so one job run carries
  an `event_count` rather than being one row per event.

  Written only by the lineage store; read under the reader's grants, inside
  the reader's tenant. Opt-outs as `AshEnterprise.Lineage.Job`'s; deleted with
  its run (`on_delete: :delete`).
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
    table "lineage_job_runs"
    repo AshEnterprise.Repo

    references do
      reference :lineage_run, on_delete: :delete
      reference :job, on_delete: :delete
    end

    custom_indexes do
      index [:organization_id, :last_event_at]
      index [:lineage_run_id]
      index [:job_id, :last_event_at]
    end
  end

  attributes do
    attribute :id, :uuid do
      primary_key? true
      allow_nil? false
      public? true
      description "Derived from the tenant and the OpenLineage run id."
    end

    attribute :run_id, :string do
      allow_nil? false
      public? true
      description "The OpenLineage `run.runId`."
    end

    attribute :job_namespace, :string, allow_nil?: false, public?: true
    attribute :job_name, :string, allow_nil?: false, public?: true

    attribute :state, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:running, :complete, :failed]
    end

    attribute :started_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :ended_at, :utc_datetime_usec, public?: true
    attribute :last_event_at, :utc_datetime_usec, allow_nil?: false, public?: true

    attribute :event_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :inputs, {:array, :map}, allow_nil?: false, default: [], public?: true
    attribute :outputs, {:array, :map}, allow_nil?: false, default: [], public?: true

    attribute :error_message, :string do
      public? true

      description "The FAIL event's error message: a reason, never content (the event's own rule)."
    end
  end

  relationships do
    belongs_to :lineage_run, AshEnterprise.Lineage.Run do
      allow_nil? false
      public? true
      attribute_public? true
    end

    belongs_to :job, AshEnterprise.Lineage.Job do
      allow_nil? false
      public? true
      attribute_public? true
    end
  end

  calculations do
    calculate :job_label, :string, expr(job_namespace <> "." <> job_name) do
      public? true
    end

    calculate :reads, :string, {AshEnterprise.Lineage.Calculations.DatasetList, field: :inputs} do
      public? true
    end

    calculate :writes,
              :string,
              {AshEnterprise.Lineage.Calculations.DatasetList, field: :outputs} do
      public? true
    end
  end

  identities do
    identity :unique_run_id, [:run_id]
  end

  actions do
    defaults [:read]

    create :record do
      description "The lineage store's upsert. Nothing else writes job runs."
      accept :*
      upsert? true

      upsert_fields [
        :lineage_run_id,
        :state,
        :started_at,
        :ended_at,
        :last_event_at,
        :event_count,
        :inputs,
        :outputs,
        :error_message
      ]
    end
  end

  @doc "A job run's job, as `namespace.name`, e.g. `ingestion.gmail.sync`."
  @spec label(t()) :: String.t()
  def label(%__MODULE__{job_namespace: namespace, job_name: name}), do: namespace <> "." <> name

  @type t :: %__MODULE__{}

  policies do
    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end
  end
end
