# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Repo.Migrations.TemporalTenantPolicySets do
  @moduledoc """
  Phase 3 slice 5 — the finale: `tenant_policy_sets` becomes a temporal
  resource. The per-org config row is period-versioned: the id lists and
  the active-bundle pointer ride periods, and every membership/pointer
  change splits the period — the retroactive compile audit's substrate
  ("which revisions was this tenant pinned to at T" is now a containment
  read).

  Hand-maintained, like the rest of this directory (the resources resolve
  their repo/table at compile time from application env, so codegen would
  bake test-only names in); the DDL mirrors what
  `mix ash_postgres.generate_migrations` emits for the resource shape:
  the `valid_at` tstzrange period, a `PRIMARY KEY (id, valid_at WITHOUT
  OVERLAPS)` GiST exclusion (per-record version history), and the
  `one_per_organization` identity as a `UNIQUE (... WITHOUT OVERLAPS)`
  exclusion.

  `one_per_organization` under periods means **one set history per
  organization** — one row per instant. The set's own period splits are
  ADJACENT half-open periods under one id (`[t₁,t₂)` / `[t₂,∞)` — bounds
  meet without overlapping), so config churn never false-conflicts (the
  same self-split adjacency proven on ControlRevision and RuleSetRevision).
  A second, *distinct* set row for an org at an overlapping instant is
  still rejected, exactly as the old plain unique index did: the semantics
  need no adaptation, only the period-aware shape.

  **Row ids are preserved (§8.1 id-churn ban — family-wide invariant).**
  The backfill adds period bounds to the existing rows in place; no row is
  re-id'd, split or re-minted. This table is *the* lineage surface the ban
  protects: `profile_revision_ids` and `rule_set_revision_ids` are id lists
  addressing revision rows across the cluster, and `active_policy_bundle_id`
  pins compiled bundles — re-id-ing the set (or letting any migration
  disturb those ids) would break byte-identical historical reconstruction
  (the replay-equivalence gate). The invariant closes out the Phase-3
  cluster with every surface it names untouched.

  The backfill opens every existing row's period at its insertion —
  `tstzrange(inserted_at AT TIME ZONE 'UTC', NULL, '[)')` (the naive
  `timestamp(0)` column pinned explicitly to UTC; slice-2 lesson): the
  configuration held from the moment it was written, which is exactly what
  today's current-pointer reads assume. No finer record existed pre-swap,
  and the compiler's gather stays a current-pointer read — its behavior is
  byte-identical.

  No overlap hazard: one row per org today (the plain unique index
  guaranteed it), one open-ended period per row — the ADD cannot fail on
  pre-existing data.
  """

  use Ecto.Migration

  @table "ash_compliance_tenant_policy_sets"

  def up do
    # The Phase 0 floor, idempotently ensured: the WITHOUT OVERLAPS
    # constraints are GiST-backed and `id` (uuid) / `organization_id` (uuid)
    # need btree_gist. Deliberately not dropped on down: the repo's
    # `min_pg_version`/`installed_extensions` declarations make it a
    # permanent part of the substrate (PR #4).
    execute("CREATE EXTENSION IF NOT EXISTS \"btree_gist\"")

    alter table(@table) do
      add :valid_at, :tstzrange
    end

    # Backfill in place: the period opens at insertion (naive UTC column
    # pinned explicitly) and never ends until a config change splits it.
    execute("""
    UPDATE #{@table}
    SET valid_at = tstzrange(inserted_at AT TIME ZONE 'UTC', NULL, '[)')
    """)

    execute("ALTER TABLE #{@table} ALTER COLUMN valid_at SET NOT NULL")

    # The version-history primary key: one record, many non-overlapping
    # periods (config changes split; adjacent splits never overlap).
    execute("ALTER TABLE #{@table} DROP CONSTRAINT #{@table}_pkey")

    execute("""
    ALTER TABLE #{@table}
    ADD CONSTRAINT #{@table}_pkey PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)
    """)

    # The plain unique index becomes an instant-unique exclusion, named to
    # the generator's convention (`<table>_<identity>_index`) so the data
    # layer maps violations to the identity's clean error.
    execute("DROP INDEX IF EXISTS #{@table}_organization_id_index")

    execute("""
    ALTER TABLE #{@table}
    ADD CONSTRAINT #{@table}_one_per_organization_index
    EXCLUDE USING gist (
      organization_id WITH =,
      valid_at WITH &&
    )
    """)
  end

  def down do
    execute("ALTER TABLE #{@table} DROP CONSTRAINT #{@table}_one_per_organization_index")

    execute("ALTER TABLE #{@table} DROP CONSTRAINT #{@table}_pkey")
    execute("ALTER TABLE #{@table} ADD CONSTRAINT #{@table}_pkey PRIMARY KEY (id)")

    execute(
      "CREATE UNIQUE INDEX #{@table}_organization_id_index ON #{@table} (organization_id)"
    )

    alter table(@table) do
      remove :valid_at
    end
  end
end
