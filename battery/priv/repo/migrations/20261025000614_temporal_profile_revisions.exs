# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Repo.Migrations.TemporalProfileRevisions do
  @moduledoc """
  Phase 3 slice 4: `profile_revisions` becomes a temporal resource — the
  period opens at creation and never ends (create+read only; nothing ever
  splits it).

  Hand-maintained, like the rest of this directory (the resources resolve
  their repo/table at compile time from application env, so codegen would
  bake test-only names in); the DDL mirrors what
  `mix ash_postgres.generate_migrations` emits for the resource shape:
  the `valid_at` tstzrange period, a `PRIMARY KEY (id, valid_at WITHOUT
  OVERLAPS)` GiST exclusion (per-record version history), and the
  `unique_revision` identity as a `UNIQUE (... WITHOUT OVERLAPS)`
  exclusion — unique at every instant. With only open-ended creates, any
  two same-keyed revisions overlap, so the exclusion fires exactly as the
  old plain unique index did; and with no update actions, a row can never
  conflict with its own history (the self-split question is structurally
  unreachable on this resource).

  **Row ids are preserved (§8.1 id-churn ban — family-wide invariant).**
  The backfill adds period bounds to the existing rows in place; no row is
  re-id'd, split or re-minted. This is load-bearing beyond this table:
  `TenantPolicySet.profile_revision_ids` and the compiler's gather address
  revisions by id, and the manifest lineages pin them — any migration that
  minted new revision ids would break byte-identical historical
  reconstruction (the replay-equivalence gate). The invariant carries into
  every subsequent Phase-3 slice.

  The backfill opens every existing row's period at its insertion —
  `tstzrange(inserted_at AT TIME ZONE 'UTC', NULL, '[)')`: the revision
  existed from the moment it was written, which is exactly what today's
  reads assume, and it makes the containment read's `effective_from`
  ordering coincide with the old `inserted_at` ordering for all pre-swap
  rows. The `AT TIME ZONE 'UTC'` conversion is explicit (slice-2 lesson):
  `inserted_at` is a `timestamp(0) without time zone` column, and the
  naive→timestamptz conversion must not ride the migrating session's
  timezone.

  No overlap hazard: every period is open-ended and keyed by the pre-swap
  unique index's exact columns, so the ADD cannot fail on pre-existing
  data.
  """

  use Ecto.Migration

  @table "ash_compliance_profile_revisions"

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
    # pinned explicitly) and never ends — create-only, nothing splits it.
    execute("""
    UPDATE #{@table}
    SET valid_at = tstzrange(inserted_at AT TIME ZONE 'UTC', NULL, '[)')
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

    # The plain unique index becomes an instant-unique exclusion, named to
    # the generator's convention (`<table>_<identity>_index`) so the data
    # layer maps violations to the identity's clean error.
    execute("DROP INDEX IF EXISTS #{@table}_profile_id_version_index")

    execute("""
    ALTER TABLE #{@table}
    ADD CONSTRAINT #{@table}_unique_revision_index
    EXCLUDE USING gist (
      profile_id WITH =,
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
      "CREATE UNIQUE INDEX #{@table}_profile_id_version_index ON #{@table} (profile_id, version)"
    )

    alter table(@table) do
      remove :valid_at
    end
  end
end
