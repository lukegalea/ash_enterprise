#!/usr/bin/env bash
# The provenance demo, scripted: the demo steps for "where did this value come from", walked on
# a loopback instance so a later change that breaks one fails here, loudly, before anyone clicks.
#
#   devenv shell -- scripts/provenance-demo.sh
#
# What it walks, in order (each prints PASS or stops the run with FAIL and its reason):
#
#   0. Preflight: the Postgres on $PGPORT belongs to this repository's devenv, the port and the
#      database are the demo's own.
#   1. A fresh instance: its own database, migrated and seeded with the demo tenant (the seed
#      ingests through the real actions), served on 127.0.0.1 only.
#   2. The seed is idempotent: a second fill returns the same rows and writes no audit event.
#   3. Demo step 1: why on a task title (its write, writer, correlation id).
#   4. Demo step 2: why on a derived field.
#   5. Demo step 3: why on a judged fact; an erased document's atoms read erased.
#   6. Demo step 4: a viewer without source read; not-found equivalence.
#   7. Demo step 5, the assistant on /mcp: PENDING until the Why surface lands (P1-H4).
#   8. Demo step 7: a recipe-written value names its publisher and grant.
#   9. Demo step 6: the clinic's scenario apply is refused and a scenario run has its own rows
#      (the clinic's own tests, from the checkout named by CLINIC_DEMO_DIR).
#
# Environment:
#   PROV_PORT        the loopback port (default 4392)
#   PROV_DB          the database, created fresh and dropped at the end; its name must contain
#                    "provdemo" (default ash_enterprise_provdemo)
#   CLINIC_DEMO_DIR  a checkout of the clinic demo at origin/main (required)
#   PROV_KEEP        1 leaves the instance and database up at the end, for a manual look
#
# It never touches another instance, port or database, and stops only the server it started.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PORT="${PROV_PORT:-4392}"
DB="${PROV_DB:-ash_enterprise_provdemo}"
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/provenance-demo.XXXXXX")"
SERVER_LOG="$LOG_DIR/server.log"
SERVER_PID=""
STEP="preflight"

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s: %s\n' "$STEP" "$1" >&2; exit 1; }

on_exit() {
  status=$?
  stop_server
  if [ "${PROV_KEEP:-0}" != 1 ] && [ -n "${DB_CREATED:-}" ]; then
    mix ecto.drop --quiet >/dev/null 2>&1 || true
  fi
  if [ "$status" -ne 0 ]; then
    printf '\nThe provenance demo FAILED at step: %s\nLogs: %s\n' "$STEP" "$LOG_DIR" >&2
  else
    printf '\nThe provenance demo passed. Logs: %s\n' "$LOG_DIR"
  fi
}
trap on_exit EXIT

# Only the process this run started: the listener on our port, and only if it runs from this checkout.
stop_server() {
  [ -n "$SERVER_PID" ] || return 0
  [ "${PROV_KEEP:-0}" != 1 ] || return 0
  local pid
  pid="$(listener_pid "$PORT")"
  if [ -n "$pid" ] && [ "$(readlink "/proc/$pid/cwd")" = "$ROOT" ]; then
    kill "$pid" 2>/dev/null || true
  fi
  kill "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
}

listener_pid() {
  ss -ltnpH "sport = :$1" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -n1
}

# --- 0. preflight -----------------------------------------------------------------------------

STEP="0 preflight"
command -v mix >/dev/null || fail "mix is not on PATH: run this inside 'devenv shell --'"
[ -n "${PGPORT:-}" ] || fail "PGPORT is not set: run this inside 'devenv shell --'"
case "$DB" in *provdemo*) ;; *) fail "PROV_DB must contain \"provdemo\" so it can never be a shared database (got $DB)";; esac
[ -n "${CLINIC_DEMO_DIR:-}" ] && [ -d "$CLINIC_DEMO_DIR" ] ||
  fail "CLINIC_DEMO_DIR must name a checkout of the clinic demo (step 6 runs there)"

pg_pid="$(listener_pid "$PGPORT")"
[ -n "$pg_pid" ] || fail "nothing listens on PGPORT=$PGPORT: 'devenv up -d' first"
pg_cwd="$(readlink "/proc/$pg_pid/cwd" || true)"
case "$pg_cwd" in
  */.devenv/state/postgres) ;;
  *) fail "the Postgres on :$PGPORT runs from '$pg_cwd', not a devenv cluster: another project may own the port";;
esac
[ -z "$(listener_pid "$PORT")" ] || fail "port $PORT is already taken: set PROV_PORT"
pass "Postgres on :$PGPORT is a devenv cluster ($pg_cwd); port $PORT and database $DB are the demo's own"

# --- 1. a fresh loopback instance --------------------------------------------------------------

STEP="1 instance"
export DB_NAME="$DB" PORT="$PORT" PHX_IP=127.0.0.1
{
  mix ecto.drop --quiet || true
  mix ecto.create --quiet
  DB_CREATED=1
  mix ash_enterprise.legacy.setup
  mix ash.setup
  mix ash_enterprise.demo
} >"$LOG_DIR/setup.log" 2>&1 || fail "database setup or demo seed failed; see $LOG_DIR/setup.log"
pass "database $DB migrated and seeded with the demo tenant"

mix phx.server >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
up=""
for _ in $(seq 1 90); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$PORT/sign-in" 2>/dev/null; then up=1; break; fi
  kill -0 "$SERVER_PID" 2>/dev/null || fail "the server exited at boot; see $SERVER_LOG"
  sleep 2
done
[ -n "$up" ] || fail "the server did not answer on 127.0.0.1:$PORT within 3 minutes; see $SERVER_LOG"
case "$(ss -ltnH "sport = :$PORT" | awk '{print $4}')" in
  127.0.0.1:"$PORT") ;;
  *) fail "the instance is not bound to loopback only";;
esac
pass "instance up on 127.0.0.1:$PORT, loopback only"

# --- 2-8. the steps ----------------------------------------------------------------------------

STEP="2-8 provenance steps"
export PGHOST=127.0.0.1
mix run scripts/provenance_demo.exs 2>&1 | tee "$LOG_DIR/steps.log"
[ "${PIPESTATUS[0]}" -eq 0 ] || fail "a step failed; see $LOG_DIR/steps.log"

# --- 9. the clinic -------------------------------------------------------------------------------

STEP="9 clinic"
(
  cd "$CLINIC_DEMO_DIR"
  MIX_TEST_PARTITION=_provdemo mix test \
    test/clinic_demo/planning/scenario_world_test.exs \
    test/clinic_demo/business_events_scenarios_test.exs --max-cases 4
) >"$LOG_DIR/clinic.log" 2>&1 || fail "the clinic tests failed; see $LOG_DIR/clinic.log"
pass "clinic: a scenario candidate is refused at apply, and a scenario run has its own rows"
