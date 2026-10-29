# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Repo.Migrations.TemporalCatalogVersions do
  @moduledoc """
  Phase 3 slice 1: `catalog_versions` becomes a temporal resource — the
  publication window IS the period.

  Hand-maintained, like the rest of this directory (the resources resolve
  their repo/table at compile time from application env, so codegen would
  bake test-only names in); the DDL mirrors what
  `mix ash_postgres.generate_migrations` emits for the resource shape:
  the `valid_at` tstzrange period, a `PRIMARY KEY (id, valid_at WITHOUT
  OVERLAPS)` GiST exclusion (per-record version history), and the
  `unique_version`/`unique_hash` identities as `UNIQUE (... WITHOUT
  OVERLAPS)` exclusions — unique at every instant.

  **Row ids are preserved.** The backfill adds period bounds to the existing
  rows in place; no row is re-id'd, split or re-minted. This is load-bearing
  beyond this table: `content_hash` transitively covers `manifest_revision`
  (sorted revision UUID lists hashed into compiled bundles, `ash_rules`
  IR), so any migration that minted new version ids would break
  byte-identical historical manifest reconstruction — the replay-equivalence
  gate. The invariant carries into every subsequent Phase-3 slice.

  The `published_at` column is dropped: the period replaces it as the single
  source of truth, and the name survives as a public `range_lower`
  calculation (filterable/sortable at the data layer), so reads keep the
  same shape. The backfill maps the column onto the period it always
  denoted: the period opens at the publication instant and never ends —
  `tstzrange(published_at, NULL, '[)')`, half-open with an inclusive lower
  bound. A row with a NULL `published_at` (created but never dated — the
  old column was nullable) opens at its `inserted_at`, which is exactly the
  visibility the old insertion-order reads gave it.

  Date↔datetime boundary (pinned convention, temporal-resources-strategy
  §2.4): a legacy inclusive `DATE` enters a half-open period as
  `T00:00:00Z` on its own day (inclusive lower); an inclusive expiry date
  becomes the exclusive `T00:00:00Z` of the following day. This column is
  already `utc_datetime_usec`, so the straight lower bound applies; the
  convention is cited here because catalog imports are where a date-only
  `published_at` could arrive (a host feeding a `DATE` lands at midnight
  UTC).

  No overlap hazard: every period is open-ended, and the exclusion keys
  (`catalog_id, version`) / (`catalog_id, content_hash`) are unchanged, so
  the ADD cannot fail on pre-existing data the way a bounded-window
  exclusion could.
  """

  use Ecto.Migration

  @table "ash_compliance_catalog_versions"

  def up do
    # The Phase 0 floor, idempotently ensured: the WITHOUT OVERLAPS
    # constraints are GiST-backed and `id` (uuid) / `version` /
    # `content_hash` (text) need btree_gist. Deliberately not dropped on
    # down: the repo's `min_pg_version`/`installed_extensions` declarations
    # make it a permanent part of the substrate (PR #4).
    execute("CREATE EXTENSION IF NOT EXISTS \"btree_gist\"")

    alter table(@table) do
      add :valid_at, :tstzrange
    end

    # Backfill the period from the publication instant: half-open
    # [published_at, ∞). A NULL published_at opens at insertion — the
    # visibility the old insertion-order reads gave it. Bounds stay
    # unbounded above: versions are append-only, nothing ever ends them.
    execute("""
    UPDATE #{@table}
    SET valid_at = tstzrange(coalesce(published_at, inserted_at), NULL, '[)')
    """)

    execute("ALTER TABLE #{@table} ALTER COLUMN valid_at SET NOT NULL")

    # The version-history primary key: one record, many non-overlapping
    # periods (this resource only ever writes one, but the shape is the
    # temporal contract).
    execute("ALTER TABLE #{@table} DROP CONSTRAINT #{@table}_pkey")

    execute("""
    ALTER TABLE #{@table}
    ADD CONSTRAINT #{@table}_pkey PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)
    """)

    # The plain unique indexes become instant-unique exclusions, named to
    # the generator's convention (`<table>_<identity>_index`) so the data
    # layer maps violations to the identity's clean error.
    execute(
      "DROP INDEX IF EXISTS #{@table}_catalog_id_version_index"
    )

    execute(
      "DROP INDEX IF EXISTS #{@table}_catalog_id_content_hash_index"
    )

    execute("""
    ALTER TABLE #{@table}
    ADD CONSTRAINT #{@table}_unique_version_index
    EXCLUDE USING gist (
      catalog_id WITH =,
      version WITH =,
      valid_at WITH &&
    )
    """)

    execute("""
    ALTER TABLE #{@table}
    ADD CONSTRAINT #{@table}_unique_hash_index
    EXCLUDE USING gist (
      catalog_id WITH =,
      content_hash WITH =,
      valid_at WITH &&
    )
    """)

    # The column's last reader is gone: the identity-preserving backfill
    # has moved every value into the period, and the `range_lower`
    # calculation re-derives the name for reads.
    alter table(@table) do
      remove :published_at
    end
  end

  def down do
    alter table(@table) do
      add :published_at, :utc_datetime_usec
    end

    execute("""
    UPDATE #{@table}
    SET published_at = lower(valid_at)
    """)

    execute("ALTER TABLE #{@table} DROP CONSTRAINT #{@table}_unique_version_index")

    execute("ALTER TABLE #{@table} DROP CONSTRAINT #{@table}_unique_hash_index")

    execute("ALTER TABLE #{@table} DROP CONSTRAINT #{@table}_pkey")
    execute("ALTER TABLE #{@table} ADD CONSTRAINT #{@table}_pkey PRIMARY KEY (id)")

    execute(
      "CREATE UNIQUE INDEX #{@table}_catalog_id_version_index ON #{@table} (catalog_id, version)"
    )

    execute(
      "CREATE UNIQUE INDEX #{@table}_catalog_id_content_hash_index ON #{@table} (catalog_id, content_hash)"
    )

    alter table(@table) do
      remove :valid_at
    end
  end
end
