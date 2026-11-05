defmodule AshEnterprise.SystemOne.StandingHead do
  @moduledoc """
  The last checkout HEAD the standards standing check judged in full, per
  tenant and repository (`AshEnterprise.Standards.StandingWorker`).

  One row per `(subject_tenant_id, repository)`: a commit sha and the time it
  was marked. The standing check skips a run when the checkout is still at
  that sha. A run narrowed by a per-question limit, or one that met a judge
  error, never calls `mark`, so the sha stays behind and the next tick looks
  again.

  **Holds no content**: a tenant id, a repository name and a sha. Sync-style
  bookkeeping, so the opt-outs are those of
  `AshEnterprise.Integration.ProjectionCursor`: `ownership: :none`,
  `tenant?: false` (the tenant is a column, because the row is written by the
  job runner across tenants), overwritten rather than soft-deleted, and not
  audited (it records a position, not a decision).

  Both actions are machinery-only (ADR 0059): only the `oban` system actor
  reaches them.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.SystemOne,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    machinery_only: [:for_scope, :mark]

  postgres do
    table "system_one_standing_heads"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :subject_tenant_id, :uuid do
      allow_nil? false
      public? true
      description "The tenant whose ledger the judged facts were written to."
    end

    attribute :repository, :string do
      allow_nil? false
      public? true
      description "The repository name in each subject id, e.g. ash_enterprise."
    end

    attribute :head, :string do
      allow_nil? false
      public? true
      description "The commit sha of the checkout when a full run last completed cleanly."
    end

    attribute :marked_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_scope, [:subject_tenant_id, :repository]
  end

  actions do
    defaults [:read]

    read :for_scope do
      description "The head of one tenant and repository, or nothing before the first full run."
      get? true
      argument :subject_tenant_id, :uuid, allow_nil?: false
      argument :repository, :string, allow_nil?: false

      filter expr(
               subject_tenant_id == ^arg(:subject_tenant_id) and repository == ^arg(:repository)
             )
    end

    create :mark do
      description "Upsert the head. Call only after a full run with no judge errors."
      accept [:subject_tenant_id, :repository, :head]
      upsert? true
      upsert_identity :unique_scope
      upsert_fields [:head, :marked_at]
      change set_attribute(:marked_at, &DateTime.utc_now/0)
    end
  end

  code_interface do
    define :for_scope, args: [:subject_tenant_id, :repository], not_found_error?: false
    define :mark
  end
end
