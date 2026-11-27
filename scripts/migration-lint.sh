#!/usr/bin/env bash
# Migration SQL lint (q43). Ecto migrations are Elixir, so `mix ash_enterprise.migrations.sql`
# first captures the SQL every migration newer than the reversibility floor
# (priv/repo/REVERSIBLE_SINCE) sends to the database; then a pinned Squawk reads it.
#
# Squawk runs every rule (.squawk.toml) and every finding is printed, but only the rules that
# break a node still running the previous release on the new schema block: dropping or
# renaming a column or table, changing a column's type, adding a NOT NULL column without a
# default. Lock-time and style rules (indexes, foreign keys, timeouts, robust statements)
# warn, because Ash codegen trips them on every migration.
#
# A blocking finding inside an ALTER TABLE on a table the same migration created (a plain
# CREATE TABLE earlier in that migration's SQL, not IF NOT EXISTS) does not block: no node
# running the previous release reads a table that did not exist. Ash codegen writes that shape
# whenever new tables reference one another (create, then alter to add columns and foreign keys).
#
# A deliberate contract step (the last step of expand/contract) is acknowledged in
# priv/repo/migration-contract-steps.json by version and rule, with a reason and a ticket.
#
#   scripts/migration-lint.sh               # self-tests, then the real run
#   scripts/migration-lint.sh --self-test   # self-tests only
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

export MIX_ENV=test
base_partition="${MIX_TEST_PARTITION:-_lint}"
squawk_version="2.69.0"
blocking='["ban-drop-column","ban-drop-table","renaming-column","renaming-table","changing-column-type","adding-required-field","adding-not-nullable-field"]'

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fresh_db() {
  export MIX_TEST_PARTITION="$1"
  mix ecto.drop --quiet --force-drop >/dev/null 2>&1 || true
  mix ecto.create --quiet
}

squawk() {
  command -v npx >/dev/null || {
    echo "npx is not on PATH: Squawk would silently lint nothing" >&2
    return 1
  }
  if [ -n "${SQUAWK:-}" ]; then "$SQUAWK" "$@"; else npx --yes "squawk-cli@${squawk_version}" "$@"; fi
}

# lint SQL_DIR ALLOWLIST_FILE : prints every finding; returns 1 listing the unacknowledged
# blocking ones.
lint() {
  local dir="$1" allow="$2" out="$work/squawk.json" f
  squawk --config .squawk.toml --reporter json "$dir"/*.sql >"$out" || true
  [ -s "$out" ] || echo '[]' >"$out"
  jq -e . "$out" >/dev/null || { echo "squawk did not produce JSON:" >&2; cat "$out" >&2; return 1; }
  jq -r '.[] | "\(.level) \(.file | split("/") | last) \(.rule_name): \(.message)"' "$out" | sort -u >&2
  for f in "$dir"/*.sql; do
    jq -Rs --arg v "$(basename "$f" .sql)" '{($v): .}' "$f"
  done | jq -s 'add // {}' >"$work/sql.json"
  jq -r --argjson blocking "$blocking" --slurpfile allow "$allow" --slurpfile sql "$work/sql.json" '
    def ident: "(?:\"[^\"]+\"|[A-Za-z_][A-Za-z0-9_$]*)";
    def table_name: "(" + ident + "(?:\\." + ident + ")?)";
    def norm: gsub("\""; "") | ascii_downcase;
    # Squawk lines and columns count from 0. The finding is inside an ALTER TABLE statement
    # (no ";" between its ALTER TABLE and the finding) on a table a plain CREATE TABLE made
    # earlier in the same file.
    def on_new_table($text):
      ($text | split("\n")) as $lines
      | (($lines[0:.line] | map(. + "\n") | join("")) + (($lines[.line] // "")[0:.column])) as $before
      | ([$before | match("\\bALTER\\s+TABLE\\s+(?:IF\\s+EXISTS\\s+)?(?:ONLY\\s+)?" + table_name; "gi")] | last) as $alter
      | if $alter == null or ($before[$alter.offset:] | contains(";")) then false
        else ($alter.captures[0].string | norm) as $table
          | [$before[0:$alter.offset]
              | match("\\bCREATE\\s+TABLE\\s+(?!IF\\s)" + table_name; "gi")
              | .captures[0].string | norm]
          | any(. == $table)
        end;
    ($allow[0].steps // []) as $steps
    | .[]
    | .rule_name as $r
    | select($blocking | index($r))
    | (.file | split("/") | last | sub("\\.sql$"; "")) as $version
    | select(on_new_table($sql[0][$version] // "") | not)
    | select(([$steps[] | select(.version == $version and .rule == $r)] | length) == 0)
    | "\($version) \($r): \(.message)"' "$out" | sort -u >"$work/blocked.txt"
  if [ -s "$work/blocked.txt" ]; then
    echo "blocking findings, not on the contract-step allowlist:" >&2
    cat "$work/blocked.txt" >&2
    return 1
  fi
}

capture() { # fixture-or-empty floor out
  local path_opt=()
  [ -z "$1" ] || path_opt=(--path "$1")
  mix ash_enterprise.migrations.sql --floor "$2" --out "$3" "${path_opt[@]}" >/dev/null
}

self_test() { # name expect fixture allowlist-json message
  local name="$1" expect="$2" fixture="$3" allow_json="$4" message="$5" out status=0
  fresh_db "${base_partition}_self"
  rm -rf "$work/sql" && mkdir -p "$work/sql"
  capture "test/fixtures/migrations/$fixture" 20000101000000 "$work/sql"
  # An empty capture (the SQL step raced the database and wrote nothing) must
  # fail here by name: squawk on nothing finds nothing, and the `fail` cases
  # below would "pass" for the wrong reason.
  ls "$work"/sql/*.sql >/dev/null 2>&1 || {
    echo "self-test '$name': the SQL capture wrote no files for $fixture" >&2
    exit 1
  }
  echo "$allow_json" >"$work/allow.json"
  out="$(lint "$work/sql" "$work/allow.json" 2>&1)" || status=$?
  if [ "$expect" = pass ] && [ "$status" -ne 0 ]; then
    echo "self-test '$name': expected a pass, it failed:" >&2
    echo "$out" >&2
    exit 1
  fi
  if [ "$expect" = fail ]; then
    [ "$status" -ne 0 ] || { echo "self-test '$name': expected a failure, it passed" >&2; exit 1; }
    grep -qF -- "$message" <<<"$out" || { echo "self-test '$name': failed, but not with '$message':" >&2; echo "$out" >&2; exit 1; }
  fi
  echo "self-test '$name': ok"
}

# Negative first.
self_test "a DROP COLUMN migration is refused" fail drop_column '{"steps":[]}' "20000101000002 ban-drop-column"
self_test "a DROP COLUMN for a different version is still refused" fail drop_column \
  '{"steps":[{"version":"20000101000009","rule":"ban-drop-column","ticket":"X-1","reason":"r"}]}' "20000101000002 ban-drop-column"
self_test "a DROP COLUMN on the allowlist with a reason passes" pass drop_column \
  '{"steps":[{"version":"20000101000002","rule":"ban-drop-column","ticket":"X-1","reason":"no node reads it"}]}' ""
self_test "a NOT NULL column added to an earlier migration's table is refused" fail required_on_existing \
  '{"steps":[]}' "20000101000002 adding-required-field"
self_test "a column type changed after CREATE TABLE IF NOT EXISTS on an existing table is refused" fail \
  create_if_not_exists '{"steps":[]}' "20000101000002 changing-column-type"
self_test "a clean migration passes" pass clean '{"steps":[]}' ""
self_test "a table altered in the migration that creates it passes" pass new_table_altered '{"steps":[]}' ""

[ "${1:-}" != "--self-test" ] || exit 0

floor="$(grep -v '^#' priv/repo/REVERSIBLE_SINCE | awk '$1 == "AshEnterprise.Repo" { print $2 }')"
[ -n "$floor" ] || { echo "priv/repo/REVERSIBLE_SINCE names no floor for AshEnterprise.Repo" >&2; exit 1; }

fresh_db "$base_partition"
mix ash_enterprise.legacy.setup >/dev/null
capture "" "$floor" "$work/real"
lint "$work/real" priv/repo/migration-contract-steps.json
mix ecto.drop --quiet --force-drop >/dev/null
echo "migration SQL lint: migrations newer than $floor pass the blocking rules"
