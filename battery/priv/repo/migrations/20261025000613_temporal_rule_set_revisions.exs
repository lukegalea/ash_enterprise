# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Repo.Migrations.TemporalRuleSetRevisions do
  @moduledoc """
  Phase 3 slice 3: `rule_set_revisions` becomes a temporal resource — the
  period records when each status held (§1), and double-activation becomes
  database-impossible via the `active_key` NULL-trick exclusion.

  Hand-maintained, like the rest of this directory (the resources resolve
  their repo/table at compile time from application env, so codegen would
  bake test-only names in); the DDL mirrors what
  `mix ash_postgres.generate_migrations` emits for the resource shape:
  the `valid_at` tstzrange period, a `PRIMARY KEY (id, valid_at WITHOUT
  OVERLAPS)` GiST exclusion (per-record version history), and both
  identities as `UNIQUE (... WITHOUT OVERLAPS)` exclusions.

  The two exclusions do different jobs:

    * `unique_revision` — one history per `(organization_id, name,
      revision)`, unique at every instant. A row's own lifecycle splits are
      ADJACENT half-open periods (`[t₁,t₂)` / `[t₂,∞)` — bounds meet
      without overlapping), so churn never false-conflicts with the row's
      own history.
    * `one_active_per_name` — one ACTIVE revision per `(organization_id,
      name)` at any instant, via `active_key` (NULL unless the row's status
      is `:active`). GiST equality never conflicts on NULLs, so
      non-active rows are unconstrained and only genuinely-active rows can
      collide. This is the waiver `scope_key` trick INVERTED — do not
      conflate them: `scope_key` substitutes a non-null sentinel so
      NULL-scoped rows DO conflict; `active_key` goes NULL precisely so
      non-active rows DON'T. Nil-org (global) actives stay mutually
      unconstrained, exactly as under the old plain unique index (GiST
      NULL semantics apply to `organization_id` too).

  **Row ids are preserved (§8.1 id-churn ban — family-wide invariant).**
  The backfill adds period bounds and the derived key to the existing rows
  in place; no row is re-id'd, split or re-minted. This is load-bearing
  beyond this table: `manifest_revision` concatenates sorted revision UUID
  lists into the compiled artifact's identity, so any migration that minted
  new revision ids would change the manifest string and break byte-identical
  historical reconstruction — the replay-equivalence gate. The invariant
  carries into every subsequent Phase-3 slice.

  Backfill semantics: every existing row's period opens at its insertion —
  `tstzrange(inserted_at AT TIME ZONE 'UTC', NULL, '[)')`: the status the
  row carries today held from the moment it was written, and no finer
  record existed pre-swap. The naive `timestamp(0)` column is pinned
  explicitly to UTC so the conversion never rides the migrating session's
  timezone (slice-2 lesson). `active_key` is derived from the stored status
  — `'active'` iff `status = 'active'`, NULL otherwise — the same constant
  `Changes.DeriveActiveKey` writes, so backfilled rows and new writes share
  one key per state.

  Overlap hazard on the ADD: `one_active_per_name` constrains only rows
  whose `active_key` is non-null, i.e. rows already `:active` today. If a
  host's existing data holds two simultaneously-active revisions of one
  (organization, name) — the drift this exclusion exists to kill — the ADD
  fails: resolve the double-active (retire one) before migrating.
  Greenfield data has none.
  """

  use Ecto.Migration

  @table "ash_compliance_rule_set_revisions"

  def up do
    # The Phase 0 floor, idempotently ensured: the WITHOUT OVERLAPS
    # constraints are GiST-backed and `id` (uuid) / `name` / `revision` /
    # `active_key` (text) need btree_gist. Deliberately not dropped on
    # down: the repo's `min_pg_version`/`installed_extensions` declarations
    # make it a permanent part of the substrate (PR #4).
    execute("CREATE EXTENSION IF NOT EXISTS \"btree_gist\"")

    alter table(@table) do
      add :active_key, :text
      add :valid_at, :tstzrange
    end

    # Backfill in place: the period opens at insertion (naive UTC column
    # pinned explicitly) and never ends until a lifecycle write splits it.
    execute("""
    UPDATE #{@table}
    SET valid_at = tstzrange(inserted_at AT TIME ZONE 'UTC', NULL, '[)')
    """)

    # The exclusion key, derived from the stored status exactly as
    # Changes.DeriveActiveKey derives it.
    execute("""
    UPDATE #{@table}
    SET active_key = 'active'
    WHERE status = 'active'
    """)

    execute("ALTER TABLE #{@table} ALTER COLUMN valid_at SET NOT NULL")

    # The version-history primary key: one record, many non-overlapping
    # periods (lifecycle updates split; adjacent splits never overlap).
    execute("ALTER TABLE #{@table} DROP CONSTRAINT #{@table}_pkey")

    execute("""
    ALTER TABLE #{@table}
    ADD CONSTRAINT #{@table}_pkey PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)
    """)

    # The plain unique index becomes an instant-unique exclusion, named to
    # the generator's convention (`<table>_<identity>_index`) so the data
    # layer maps violations to the identity's clean error.
    execute(
      "DROP INDEX IF EXISTS #{@table}_organization_id_name_revision_index"
    )

    execute("""
    ALTER TABLE #{@table}
    ADD CONSTRAINT #{@table}_unique_revision_index
    EXCLUDE USING gist (
      organization_id WITH =,
      name WITH =,
      revision WITH =,
      valid_at WITH &&
    )
    """)

    # The double-activation killer.
    execute("""
    ALTER TABLE #{@table}
    ADD CONSTRAINT #{@table}_one_active_per_name_index
    EXCLUDE USING gist (
      organization_id WITH =,
      name WITH =,
      active_key WITH =,
      valid_at WITH &&
    )
    """)
  end

  def down do
    execute("ALTER TABLE #{@table} DROP CONSTRAINT #{@table}_one_active_per_name_index")

    execute("ALTER TABLE #{@table} DROP CONSTRAINT #{@table}_unique_revision_index")

    execute("ALTER TABLE #{@table} DROP CONSTRAINT #{@table}_pkey")
    execute("ALTER TABLE #{@table} ADD CONSTRAINT #{@table}_pkey PRIMARY KEY (id)")

    execute(
      "CREATE UNIQUE INDEX #{@table}_organization_id_name_revision_index ON #{@table} (organization_id, name, revision)"
    )

    alter table(@table) do
      remove :valid_at
      remove :active_key
    end
  end
end
