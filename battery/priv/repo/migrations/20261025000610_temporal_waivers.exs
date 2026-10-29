# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Repo.Migrations.TemporalWaivers do
  @moduledoc """
  Phase 3: `policy_overrides` becomes a temporal resource — the in-force
  window IS the period.

  Hand-maintained, like the rest of this directory (the resources resolve
  their repo/table at compile time from application env, so codegen would
  bake test-only names in); the DDL mirrors what
  `mix ash_postgres.generate_migrations` emits for the resource shape:
  the `valid_at` tstzrange period, a `PRIMARY KEY (id, valid_at WITHOUT
  OVERLAPS)` GiST exclusion (per-record version history), and the
  `one_in_force_per_scope` identity as `UNIQUE (... WITHOUT OVERLAPS)` —
  the DB-enforced non-overlap that kills the double-granted waiver.

  `starts_at`/`expires_at` columns are dropped: the period replaces them
  as the single source of truth (they survive as derived calculations over
  `valid_at`, so plain reads keep the names). Existing rows are backfilled
  from their declared window before the columns go, and `scope_key` — the
  non-null stand-in for the nullable scope pair in the exclusion (GiST
  equality never conflicts on NULLs) — is derived with the same
  unit-separator concat `Changes.DeriveScopeKey` uses, so backfilled rows
  and new grants share one key per scope.

  If a host's existing data already contains two overlapping waivers for
  the same (organization, rule, scope), the exclusion ADD fails: resolve
  the overlap (lapse or supersede one) before migrating. Greenfield data
  has none.
  """

  use Ecto.Migration

  @table "ash_compliance_policy_overrides"

  def up do
    # The Phase 0 floor, now physically installed: the WITHOUT OVERLAPS
    # exclusions are GiST-backed and every non-GiST-native column in them
    # (uuid, text) needs btree_gist. Deliberately not dropped on down: the
    # repo's `min_pg_version`/`installed_extensions` declarations make it a
    # permanent part of the substrate (PR #4).
    execute("CREATE EXTENSION IF NOT EXISTS \"btree_gist\"")

    alter table(@table) do
      add :scope_key, :text
      add :valid_at, :tstzrange
    end

    # Backfill scope_key exactly as Changes.DeriveScopeKey derives it.
    execute("""
    UPDATE #{@table}
    SET scope_key = coalesce(scope_subject_type, '') || E'\\x1f' || coalesce(scope_subject_id, '')
    """)

    # Backfill the period from the declared window: half-open
    # [starts_at, expires_at) — nil bounds stay unbounded (a nil starts_at
    # was "in force since always", a nil expires_at evergreen), which is
    # what the old read filter expressed.
    execute("""
    UPDATE #{@table}
    SET valid_at = tstzrange(starts_at, expires_at, '[)')
    """)

    execute("ALTER TABLE #{@table} ALTER COLUMN scope_key SET NOT NULL")
    execute("ALTER TABLE #{@table} ALTER COLUMN valid_at SET NOT NULL")

    alter table(@table) do
      remove :starts_at
      remove :expires_at
    end

    # The version-history primary key: one record, many non-overlapping
    # periods.
    execute("ALTER TABLE #{@table} DROP CONSTRAINT #{@table}_pkey")

    execute("""
    ALTER TABLE #{@table}
    ADD CONSTRAINT #{@table}_pkey PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)
    """)

    # The double-grant killer: one in-force override per
    # (organization_id, rule_id, scope_key) at any instant. Named to the
    # generator's convention (`<table>_<identity>_index`) so the data layer
    # maps violations to the identity's clean error.
    execute("""
    ALTER TABLE #{@table}
    ADD CONSTRAINT #{@table}_one_in_force_per_scope_index
    EXCLUDE USING gist (
      organization_id WITH =,
      rule_id WITH =,
      scope_key WITH =,
      valid_at WITH &&
    )
    """)
  end

  def down do
    execute("ALTER TABLE #{@table} DROP CONSTRAINT #{@table}_one_in_force_per_scope_index")
    execute("ALTER TABLE #{@table} DROP CONSTRAINT #{@table}_pkey")
    execute("ALTER TABLE #{@table} ADD CONSTRAINT #{@table}_pkey PRIMARY KEY (id)")

    alter table(@table) do
      add :starts_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
    end

    execute("""
    UPDATE #{@table}
    SET starts_at = lower(valid_at), expires_at = upper(valid_at)
    """)

    alter table(@table) do
      remove :valid_at
      remove :scope_key
    end
  end
end
