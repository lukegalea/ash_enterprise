defmodule AshEnterprise.Process.TriggerCursor do
  @moduledoc """
  How far the trigger dispatcher has read into one tenant's audit chain.

  One row per tenant, holding the highest `sequence` that has been dispatched. The design and
  the measurements behind it are in `docs/plans/event-triggered-processes.md` §2; the short
  version is that `AshEnterprise.Audit.EventLog.sequence` is a `bigserial`, which is normally
  the wrong thing to build a change feed on — but `AshEvents` takes a per-tenant
  `pg_advisory_xact_lock` before inserting each event and holds it to `COMMIT`, so within one
  tenant sequence order *is* commit order and a high-water mark cannot skip an event.

  ## One cursor per tenant, and never a global one

  That guarantee comes from a **two-argument** advisory lock keyed on the tenant. Events with
  no tenant use the **one-argument** form, which Postgres treats as a separate lock space
  entirely — so the `NULL`-tenant chain has no ordering guarantee at all, not merely a weaker
  one. It gets its own row here (`organization_id IS NULL`) and is best-effort by
  construction.

  ## Not audited

  A cursor is bookkeeping. It changes once per sweep and says nothing an auditor wants that
  `AshEnterprise.Process.TriggerDispatch` does not say better — and two logs describing the
  same fact will eventually disagree.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Process,
    ownership: :none,
    lifecycle?: false,
    audit?: false,
    archival?: false

  postgres do
    table "process_trigger_cursors"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :last_sequence, :integer do
      allow_nil? false
      default 0
      public? true
      description "The highest audit-event sequence dispatched for this tenant."
    end

    attribute :last_dispatched_at, :utc_datetime_usec do
      public? true
      description "When the sweep last advanced this cursor. Nil until the first sweep."
    end
  end

  calculations do
    # A stalled dispatcher should be a detected condition rather than a support ticket. This is
    # what a health check reads; it is a calculation rather than a column because a stored
    # staleness would itself go stale.
    calculate :lag_seconds, :integer, expr(date_diff(last_dispatched_at, now(), :second)) do
      public? true
      description "Seconds since this tenant's cursor last advanced. Nil before the first sweep."
    end
  end

  identities do
    # One cursor per tenant, enforced by the database rather than by the sweeper remembering.
    #
    # `all_tenants? true` with `organization_id` listed explicitly, rather than an empty key
    # list scoped per tenant. An identity defaults to `all_tenants? false`, which makes
    # AshPostgres *prepend* the multitenancy attribute to the index — so the tenant-scoped
    # form would want no keys at all, which Ash rejects. Saying it the other way round gives
    # exactly the same index and is the only spelling the DSL accepts.
    #
    # The `NULL`-tenant chain gets one row here too. Postgres treats NULLs as distinct in a
    # unique index, so that row is not actually protected by this constraint — see the
    # moduledoc for why that chain is best-effort anyway.
    identity :one_per_tenant, [:organization_id] do
      all_tenants? true
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [:last_sequence, :last_dispatched_at]
      upsert? true
      upsert_identity :one_per_tenant
    end

    update :advance do
      accept [:last_sequence]
      change set_attribute(:last_dispatched_at, &DateTime.utc_now/0)
    end
  end

  code_interface do
    define :create
    define :advance, args: [:last_sequence]
  end
end
