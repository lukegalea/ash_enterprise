#!/usr/bin/env bash
# restart-check.sh [ROUNDS] : cold restarts of the stack, with data, each checked.
#
# Run from a devenv shell that imports devenv/observability.nix, against the
# state dir `observability` uses ($OBSERVABILITY_STATE_DIR, or the default). Each
# round is `observability up`, a burst of OTLP traffic, checks, `observability
# down`. A round passes when up reported ready, every service is still running
# within budget, ClickHouse logged no MEMORY_LIMIT_EXCEEDED, the collector logged
# no failed write, and SigNoz returns every span the round sent.
#
# Start it on a state dir that already holds a few days of data (or let earlier
# rounds build it up): the failure it guards against is ClickHouse running out of
# memory on the merges it resumes at startup.
set -uo pipefail

ROUNDS="${1:-5}"
REQUESTS="${RESTART_CHECK_REQUESTS:-40}"
SPANS="${RESTART_CHECK_SPANS:-25}"
: "${DEVENV_STATE:?run this from a devenv shell}"
STATE="${OBSERVABILITY_STATE_DIR:-$DEVENV_STATE/observability}"
LOGS="$STATE/logs"
RUN_ID="$(date +%s)"
failed=0

say() { printf 'restart-check: %s\n' "$*"; }
hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }

send_round() {
  local round="$1" s spans trace now
  for _ in $(seq 1 "$REQUESTS"); do
    trace="$(hex 16)" now="$(date +%s%N)" spans=""
    for s in $(seq 1 "$SPANS"); do
      spans+="${spans:+,}{\"traceId\":\"$trace\",\"spanId\":\"$(hex 8)\",\"name\":\"restart-check span $s\",\"kind\":2,"
      spans+="\"startTimeUnixNano\":\"$now\",\"endTimeUnixNano\":\"$((now + s * 1000000))\","
      spans+="\"attributes\":[{\"key\":\"check.run\",\"value\":{\"stringValue\":\"$RUN_ID-$round\"}},"
      spans+="{\"key\":\"db.statement\",\"value\":{\"stringValue\":\"SELECT $s\"}}]}"
    done
    curl -sf -o /dev/null -X POST "$OBSERVABILITY_OTLP_ENDPOINT/v1/traces" -H 'content-type: application/json' \
      -d "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"restart-check\"}}]},\"scopeSpans\":[{\"scope\":{\"name\":\"restart-check\"},\"spans\":[$spans]}]}]}" ||
      return 1
  done
}

count_round() {
  local now
  now="$(date +%s%3N)"
  curl -sf -X POST "$OBSERVABILITY_SIGNOZ_URL/api/v5/query_range" \
    -H "SIGNOZ-API-KEY: $OBSERVABILITY_SIGNOZ_API_KEY" -H 'content-type: application/json' \
    -d "{\"schemaVersion\":\"v1\",\"start\":$((now - 3600000)),\"end\":$now,\"requestType\":\"raw\",\"compositeQuery\":{\"queries\":[{\"type\":\"builder_query\",\"spec\":{\"name\":\"A\",\"signal\":\"traces\",\"limit\":10000,\"selectFields\":[{\"name\":\"name\"}],\"filter\":{\"expression\":\"check.run = '$RUN_ID-$1'\"}}}]}}" |
    jq '[.data.data.results[0].rows[]?] | length'
}

for round in $(seq 1 "$ROUNDS"); do
  problems=()
  t0=$SECONDS
  if ! observability up > "$STATE/restart-check-up.log" 2>&1; then
    problems+=("up failed: $(grep 'observability: error' "$STATE/restart-check-up.log" | tail -n1)")
  else
    ready="$(sed -n 's/^observability: \(ready in [0-9]*s\)$/\1/p' "$STATE/restart-check-up.log")"
    # shellcheck disable=SC1091
    . "$STATE/env"
    send_round "$round" || problems+=("the collector refused OTLP traffic")
    expected=$((REQUESTS * SPANS)) got=0
    for _ in $(seq 1 30); do
      got="$(count_round "$round" || echo 0)"
      [ "${got:-0}" -ge "$expected" ] && break
      sleep 2
    done
    [ "${got:-0}" -ge "$expected" ] || problems+=("SigNoz returned $got of $expected spans")
    status_out="$(observability status 2>&1)"
    case $? in
      0) ;;
      2) problems+=("over budget: $(echo "$status_out" | grep '^budget:')") ;;
      *) problems+=("a service stopped: $(echo "$status_out" | awk '$NF == "stopped" {printf "%s ", $1}')") ;;
    esac
    n="$(grep -c MEMORY_LIMIT_EXCEEDED "$LOGS/clickhouse.log" 2>/dev/null || true)"
    [ "${n:-0}" -eq 0 ] || problems+=("ClickHouse logged $n MEMORY_LIMIT_EXCEEDED")
    n="$(grep -c 'Could not write' "$LOGS/collector.log" 2>/dev/null || true)"
    [ "${n:-0}" -eq 0 ] || problems+=("the collector logged $n failed writes")
    budget="$(echo "$status_out" | grep '^budget:')"
  fi
  observability down > /dev/null 2>&1 || problems+=("down failed")
  if [ "${#problems[@]}" -eq 0 ]; then
    say "round $round of $ROUNDS: ok ($ready; $got spans back; $budget; $((SECONDS - t0))s)"
  else
    failed=1
    say "round $round of $ROUNDS: FAILED"
    printf '  - %s\n' "${problems[@]}"
  fi
done

if [ "$failed" -ne 0 ]; then
  say "failures above"
  exit 1
fi
say "all $ROUNDS rounds passed"
