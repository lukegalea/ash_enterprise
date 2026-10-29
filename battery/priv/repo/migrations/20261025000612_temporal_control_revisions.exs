# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Repo.Migrations.TemporalControlRevisions do
  @moduledoc """
  Phase 3 slice 2: `control_revisions` becomes a temporal resource — the
  period records when each status held (§1); containment reads only, no
  single-active exclusion (§8.2 ruling iii).

  Hand-maintained, like the rest of this directory (the resources resolve
  their repo/table at compile time from application env, so codegen would
  bake test-only names in); the DDL mirrors what
  `mix ash_postgres.generate_migrations` emits for the resource shape:
  the `valid_at` tstzrange period, a `PRIMARY KEY (id, valid_at WITHOUT
  OVERLAPS)` GiST exclusion (per-record version history), and the
  `unique_revision` identity as a `UNIQUE (... WITHOUT OVERLAPS)`
  exclusion — unique at every instant. That exclusion constrains only
  same-`(control_id, version)` pairs: a lifecycle update splits the row
  into ADJACENT periods under one id (`[t₁,t₂)` / `[t₂,∞)` — half-open
  bounds meet without overlapping), so a row's own history cannot
  false-conflict. It is NOT a single-active constraint: different
  versions of one control never conflict, and multi-active stays legal
  (§8.2 preserves today's behavior; the `active_key` dividend moved
  exclusively to slice 3).

  **Row ids are preserved (§8.1 id-churn ban — family-wide invariant).**
  The backfill adds period bounds to the existing rows in place; no row is
  re-id'd, split or re-minted. This is load-bearing beyond this table:
  `manifest_revision` concatenates sorted revision UUID lists into the
  compiled artifact's identity, so any migration that minted new revision
  ids would change the manifest string and break byte-identical historical
  reconstruction — the replay-equivalence gate. The invariant carries into
  every subsequent Phase-3 slice.

  The backfill opens every existing row's period at its insertion —
  `tstzrange(inserted_at AT TIME ZONE 'UTC', NULL, '[)')`: the status the
  row carries today held from the moment it was written, which is exactly
  what today's reads assume, and it makes the containment read's
  `effective_from` ordering coincide with the old `inserted_at` ordering
  for all pre-swap rows. The `AT TIME ZONE 'UTC'` matters: `inserted_at`
  is a `timestamp(0) without time zone` column (Ecto stores UTC), and the
  naive→timestamptz conversion must not depend on the migrating session's
  timezone. A later lifecycle update (activate/withdraw) splits the
  period at the write instant from then on — history before the swap is
  one undivided "as inserted" period, which is the truthful reading: no
  finer record existed.

  No overlap hazard: every backfilled period is open-ended and keyed by
  the pre-swap unique index's exact columns, so the ADD cannot fail on
  pre-existing data.
  """

  use Ecto.Migration

  @table "ash_compliance_control_revisions"

  def up do
    # The Phase 0 floor, idempotently ensured: the WITHOUT OVERLAPS
    # constraints are GiST-backed and `id` (uuid) / `version` (text) need
    # btree_gist. Deliberately not dropped on down: the repo's
    # `min_pg_version`/`installed_extensions` declarations make it a
    # permanent part of the substrate (PR #4).
    execute("CREATE EXTENSION IF NOT EXISTS \"btree_gist\"")

    alter table(@table) do
      add :valid_at, :tstzrange
    end

    # Backfill in place: the period opens at insertion (naive UTC column
    # pinned explicitly) and never ends until a lifecycle write splits it.
    execute("""
    UPDATE #{@table}
    SET valid_at = tstzrange(inserted_at AT TIME ZONE 'UTC', NULL, '[)')
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
    execute("DROP INDEX IF EXISTS #{@table}_control_id_version_index")

    execute("""
    ALTER TABLE #{@table}
    ADD CONSTRAINT #{@table}_unique_revision_index
    EXCLUDE USING gist (
      control_id WITH =,
      version WITH =,
      valid_at WITH &&
    )
    """)
  end

  def down do
    execute("ALTER TABLE #{@table} DROP CONSTRAINT #{@table}_unique_revision_index")

    execute("ALTER TABLE #{@table} DROP CONSTRAINT #{@table}_pkey")
    execute("ALTER TABLE #{@table} ADD CONSTRAINT #{@table}_pkey PRIMARY KEY (id)")

    execute(
      "CREATE UNIQUE INDEX #{@table}_control_id_version_index ON #{@table} (control_id, version)"
    )

    alter table(@table) do
      remove :valid_at
    end
  end
end
