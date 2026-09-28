#!/usr/bin/env bash
# Replay every migration into a non-public schema, the way the VendorPM
# workspace hosts this application (ASH_SCHEMA=canonical, see config/dev.exs),
# and fail if any foreign key crosses out of that schema.
#
# Why: AshPostgres writes each foreign key to a schema-less resource with a
# literal prefix -- whatever AshEnterprise.Repo.default_prefix/0 returned on the
# machine that ran `mix ash.codegen`. A literal "public" (or "canonical") works
# where it was generated and breaks the other layout with
# `relation "public.bpmn_definitions" does not exist`. The fix in a migration is
# `prefix: prefix()`; this script is what notices a regenerated one that lost it.
#
# Uses its own test partition, so it never touches the suite's database.
#
#   scripts/schema-portable-migrations.sh            # schema "canonical"
#   ASH_SCHEMA=other scripts/schema-portable-migrations.sh
set -euo pipefail

export MIX_ENV=test
export ASH_SCHEMA="${ASH_SCHEMA:-canonical}"
export MIX_TEST_PARTITION="${MIX_TEST_PARTITION:-_schema_portable}"

db="ash_enterprise_test${MIX_TEST_PARTITION}"
export PGPASSWORD="${DB_PASSWORD:-postgres}"
psql_q() {
  psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${DB_USER:-postgres}" \
    -d "$db" --no-psqlrc -v ON_ERROR_STOP=1 -tAq -c "$1"
}

mix ecto.drop --quiet --force-drop >/dev/null 2>&1 || true
mix ecto.create --quiet
psql_q "CREATE SCHEMA IF NOT EXISTS \"$ASH_SCHEMA\";"
mix ash_enterprise.legacy.setup >/dev/null
mix ash.setup --quiet

tables=$(psql_q "select count(*) from pg_tables where schemaname = '$ASH_SCHEMA';")
[ "$tables" -gt 0 ] || { echo "no tables were created in $ASH_SCHEMA" >&2; exit 1; }

crossing=$(psql_q "select n.nspname || '.' || c.conname || ' -> ' || rn.nspname || '.' || r.relname
  from pg_constraint c
  join pg_namespace n on n.oid = c.connamespace
  join pg_class r on r.oid = c.confrelid
  join pg_namespace rn on rn.oid = r.relnamespace
  where c.contype = 'f' and n.nspname = '$ASH_SCHEMA' and rn.nspname <> n.nspname;")
if [ -n "$crossing" ]; then
  echo "foreign keys leave $ASH_SCHEMA (use prefix: prefix() in the migration):" >&2
  echo "$crossing" >&2
  exit 1
fi

mix ecto.drop --quiet --force-drop >/dev/null
echo "migrations replay into schema \"$ASH_SCHEMA\": $tables tables, no foreign key leaves it"
