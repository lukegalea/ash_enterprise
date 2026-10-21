defmodule AshEnterprise.Lineage.Job do
  @moduledoc """
  One OpenLineage job, per tenant: `ingestion.gmail.sync`,
  `canonical.projection.gmail`, `canonical.message.create`. The lineage
  graph's job nodes (`AshEnterprise.Lineage.Graph`), with the datasets the
  job reads and writes and the state of its latest run.

  Written only by `AshEnterprise.Lineage.Recorder`; read under the reader's
  grants (a read grant on this resource), inside the reader's tenant.

  Opt-outs: organization-owned reference-style data with no owner, no
  lifecycle, no soft delete (retention deletes, `AshEnterprise.Lineage.Retention`),
  no audit (it is derived telemetry, rewritten on every flush), and no
  lineage of its own (`lineage?: false`: recording a run must not emit one).
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
    table "lineage_jobs"
    repo AshEnterprise.Repo

    custom_indexes do
      index [:organization_id, :last_run_at]
    end
  end

  attributes do
    attribute :id, :uuid do
      primary_key? true
      allow_nil? false
      public? true
      description "Derived from the tenant, namespace and name (`Recorder.derive_id/1`)."
    end

    attribute :namespace, :string do
      allow_nil? false
      public? true
      description ~S(The OpenLineage job namespace, e.g. "ingestion".)
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      description ~S(The OpenLineage job name, e.g. "gmail.sync".)
    end

    attribute :label, :string do
      allow_nil? false
      public? true

      description ~S(`namespace.name`, e.g. "ingestion.gmail.sync": what pickers and the graph show.)
    end

    attribute :inputs, {:array, :map} do
      allow_nil? false
      default []
      public? true
      description "Datasets the job reads, each a namespace and a name."
    end

    attribute :outputs, {:array, :map} do
      allow_nil? false
      default []
      public? true
      description "Datasets the job writes, each a namespace and a name."
    end

    attribute :last_state, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:running, :complete, :failed]
    end

    attribute :last_run_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "The time of the latest event of the latest run."
    end

    attribute :last_job_run_id, :uuid, public?: true
    attribute :last_lineage_run_id, :uuid, public?: true

    attribute :last_error, :string do
      public? true
      description "The latest run's error message, when it failed. Structural, as the event's."
    end

    attribute :run_count, :integer do
      allow_nil? false
      default 0
      public? true
    end
  end

  relationships do
    has_many :job_runs, AshEnterprise.Lineage.JobRun do
      public? true
    end
  end

  identities do
    identity :unique_job, [:namespace, :name]
  end

  actions do
    defaults [:read]

    create :record do
      description "The lineage store's upsert. Nothing else writes jobs."
      accept :*
      upsert? true

      upsert_fields [
        :inputs,
        :outputs,
        :last_state,
        :last_run_at,
        :last_job_run_id,
        :last_lineage_run_id,
        :last_error,
        :run_count
      ]
    end

    destroy :prune do
      description "Retention: deletes jobs not seen inside the window."
    end
  end

  @doc "A job's display label, `namespace.name`, e.g. `ingestion.gmail.sync`."
  @spec label_for(String.t(), String.t()) :: String.t()
  def label_for(namespace, name), do: namespace <> "." <> name

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
