# shellcheck shell=bash
# observability: SigNoz and GlitchTip beside the app, without Docker.
#
# `up` is idempotent: it starts what is not running, runs first-time init once,
# and rewrites the env file. Everything binds loopback. Only processes this
# script recorded are ever signalled, and each record is checked before a signal
# because PIDs are reused on shared hosts.
#
# Provided by the devenv module through the environment: OBS_* package paths and
# settings. See devenv/observability.nix.

: "${DEVENV_STATE:?run this from a devenv shell}"

ROOT="${OBSERVABILITY_STATE_DIR:-$DEVENV_STATE/observability}"
RUN="$ROOT/run" LOGS="$ROOT/logs" DATA="$ROOT/data" SECRETS="$ROOT/secrets" MARKERS="$ROOT/markers"
ENV_FILE="$ROOT/env" PORTS_FILE="$ROOT/ports" CONFIG_FILE="$ROOT/config.env"
# GlitchTip's database and role live in the project's shared Postgres cluster, so their
# names carry a hash of this state directory: two checkouts of one project (git worktrees)
# each get their own, and neither resets the other's password or admin user.
GT_DB="observability_glitchtip_$(printf '%s' "$ROOT" | sha256sum | cut -c1-8)"
SERVICES=(clickhouse collector signoz glitchtip)
PORT_NAMES=(CLICKHOUSE_HTTP CLICKHOUSE_TCP CLICKHOUSE_INTERSERVER KEEPER RAFT OTLP_GRPC OTLP_HTTP COLLECTOR_HEALTH SIGNOZ GLITCHTIP OPAMP)

log() { printf 'observability: %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

# A per-host override file, for what the invocation cannot carry: fixed ports and
# public URLs on a hosted workspace. The process environment wins over it.
load_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      OBSERVABILITY_*) [ -n "${!key:-}" ] || export "$key=$value" ;;
    esac
  done < "$CONFIG_FILE"
}

# ---------------------------------------------------------------------------
# Process records
# ---------------------------------------------------------------------------

proc_start() { sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f20; }
boot_id() { cat /proc/sys/kernel/random/boot_id; }
record_file() { echo "$RUN/$1.record"; }

# Which record, if any, is still the process we started.
alive() {
  local rec pid start boot
  rec="$(record_file "$1")"
  [ -f "$rec" ] || return 1
  read -r pid start boot < "$rec" || return 1
  [ -d "/proc/$pid" ] || return 1
  [ "$(proc_start "$pid")" = "$start" ] && [ "$(boot_id)" = "$boot" ]
}
record_pid() { cut -d' ' -f1 "$(record_file "$1")"; }

# Direct children only recursion, so a neighbour's process can never be counted.
descendants() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null || true); do
    echo "$child"
    descendants "$child"
  done
}

# True when this host has a systemd user manager to put scopes in. Strictly
# optional: a container has none, and everything works without it.
have_user_scopes() {
  [ -z "${OBSERVABILITY_NO_SYSTEMD:-}" ] &&
    command -v systemd-run >/dev/null 2>&1 &&
    systemctl --user is-system-running >/dev/null 2>&1
}

unit_name() { echo "observability-$(echo "$ROOT" | sha256sum | cut -c1-8)-$1"; }

# launch NAME MEMORY_MAX CMD...  Runs CMD detached and records its identity.
launch() {
  local name="$1" memmax="$2"
  shift 2
  local cmd=("$@") rec tmp
  if have_user_scopes; then
    cmd=(systemd-run --user --scope --quiet --collect --unit="$(unit_name "$name")" -p "MemoryMax=$memmax" -p MemorySwapMax=0 -- "${cmd[@]}")
  fi
  rec="$(record_file "$name")"
  tmp="$rec.$$"
  : > "$LOGS/$name.log"
  # The child writes its own PID and then execs, so the record names the service
  # itself. Fd 9 is the up lock and must not outlive this script.
  # shellcheck disable=SC2016
  setsid bash -c 'echo $$ > "$0"; exec "$@"' "$tmp" "${cmd[@]}" >> "$LOGS/$name.log" 2>&1 < /dev/null 9>&- &
  disown
  local pid="" i
  for i in $(seq 1 100); do
    [ -s "$tmp" ] && pid="$(cat "$tmp")" && break
    sleep 0.05
  done
  [ -n "$pid" ] || die "$name failed to start (no pid written)"
  printf '%s %s %s\n' "$pid" "$(proc_start "$pid")" "$(boot_id)" > "$rec"
  rm -f "$tmp"
}

# wait_ready NAME SECONDS CMD...  0 when CMD succeeds, 1 when the service's own
# process has exited, 2 on timeout. It never waits out the clock on a dead process.
wait_ready() {
  local name="$1" seconds="$2"
  shift 2
  local i
  for i in $(seq 1 $((seconds * 4))); do
    "$@" >/dev/null 2>&1 && return 0
    alive "$name" || return 1
    sleep 0.25
  done
  return 2
}

log_tail() { tail -n "${2:-15}" "$LOGS/$1.log" 2>/dev/null | sed 's/^/    /' >&2 || true; }

# bring_up NAME LABEL SECONDS CMD...  Starts NAME with start_NAME and waits for CMD.
# A service that exits while starting (the collector does when ClickHouse refuses
# its first writes) is started again, a few times, before up gives up loudly.
bring_up() {
  local name="$1" label="$2" seconds="$3"
  shift 3
  local attempt rc=0 tries="${OBSERVABILITY_START_ATTEMPTS:-4}"
  for attempt in $(seq 1 "$tries"); do
    "start_$name"
    rc=0
    wait_ready "$name" "$seconds" "$@" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    if [ "$rc" -eq 1 ]; then
      log "$label exited while starting (attempt $attempt of $tries); the end of its log:"
    else
      log "$label was not ready after ${seconds}s (attempt $attempt of $tries); the end of its log:"
      stop_service "$name"
    fi
    log_tail "$name"
    rm -f "$(record_file "$name")"
    [ "$attempt" -lt "$tries" ] && sleep $((attempt * 5))
  done
  die "$label did not start after $tries attempts; see $LOGS/$name.log"
}

# The last word before "ready": every service is still the process we started and
# ClickHouse answers. A stack that reports ready with a dead collector is a
# workspace whose links show nothing.
verify_running() {
  local name dead=""
  for name in "${SERVICES[@]}"; do
    alive "$name" || dead="$dead $name"
  done
  [ -z "$dead" ] || return 1
  ch -q "select 1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Ports, secrets, env
# ---------------------------------------------------------------------------

port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

port_service() {
  case "$1" in
    CLICKHOUSE_*|KEEPER|RAFT) echo clickhouse ;;
    OTLP_*|COLLECTOR_HEALTH) echo collector ;;
    SIGNOZ|OPAMP) echo signoz ;;
    GLITCHTIP) echo glitchtip ;;
  esac
}

# Free dynamic ports by default, fixed when OBSERVABILITY_PORT_<NAME> is set, and
# kept stable between runs so URLs do not change under a running app.
allocate_ports() {
  local name var value service taken=""
  # shellcheck disable=SC1090
  [ -f "$PORTS_FILE" ] && . "$PORTS_FILE"
  local out=""
  for name in "${PORT_NAMES[@]}"; do
    var="OBSERVABILITY_PORT_$name"
    value="${!var:-}"
    service="$(port_service "$name")"
    if [ -n "$value" ]; then
      if ! alive "$service" && port_busy "$value"; then
        die "port $value (requested through $var) is already in use"
      fi
    else
      value="${!name:-}"
      if [ -n "$value" ] && ! alive "$service" && port_busy "$value"; then
        log "port $value for $name was taken; choosing another"
        value=""
      fi
      if [ -z "$value" ]; then
        local candidate range=20000-30999
        # OpAMP's port is patched into the SigNoz binary in place, and has only
        # four digits of room. See signoz_binary.
        [ "$name" = OPAMP ] && range=4400-9000
        for _ in $(seq 1 200); do
          candidate="$(shuf -i "$range" -n 1)"
          case " $taken " in *" $candidate "*) continue ;; esac
          port_busy "$candidate" || { value="$candidate"; break; }
        done
        [ -n "$value" ] || die "no free port found for $name"
      fi
    fi
    taken="$taken $value"
    printf -v "$name" '%s' "$value"
    out+="$name=$value"$'\n'
  done
  printf '%s' "$out" > "$PORTS_FILE"
}

gen_secret() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }

ensure_secrets() {
  local file="$SECRETS/values"
  if [ ! -f "$file" ]; then
    (
      umask 077
      local pub
      pub="$(gen_secret 16)"
      cat > "$file" <<VALUES
SECRET_KEY=$(gen_secret 32)
JWT_SECRET=$(gen_secret 32)
UI_PASSWORD=Obs-$(gen_secret 8)-1!
GT_TOKEN=$(gen_secret 32)
GT_DB_PASSWORD=$(gen_secret 16)
GT_PUBLIC_KEY=${pub:0:8}-${pub:8:4}-4${pub:13:3}-a${pub:17:3}-${pub:20:12}
VALUES
    )
  fi
  # shellcheck disable=SC1090
  . "$file"
  SIGNOZ_API_KEY="$(cat "$SECRETS/signoz-api-key" 2>/dev/null || true)"
  GT_PROJECT_ID="$(cat "$MARKERS/glitchtip-project-id" 2>/dev/null || echo 1)"
}

signoz_public_url() { echo "${OBSERVABILITY_SIGNOZ_PUBLIC_URL:-http://127.0.0.1:$SIGNOZ}"; }
glitchtip_public_url() { echo "${OBSERVABILITY_GLITCHTIP_PUBLIC_URL:-http://127.0.0.1:$GLITCHTIP}"; }

write_env() {
  local tmp="$ENV_FILE.$$"
  (
    umask 077
    {
      echo "# Written by 'observability up'. Sourced by the devenv shell."
      echo "export OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:$OTLP_HTTP"
      echo "export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf"
      echo "export SENTRY_DSN=http://${GT_PUBLIC_KEY//-/}@127.0.0.1:$GLITCHTIP/$GT_PROJECT_ID"
      echo "export OBSERVABILITY_OTLP_ENDPOINT=http://127.0.0.1:$OTLP_HTTP"
      echo "export OBSERVABILITY_OTLP_GRPC_ENDPOINT=127.0.0.1:$OTLP_GRPC"
      echo "export OBSERVABILITY_GLITCHTIP_DSN=http://${GT_PUBLIC_KEY//-/}@127.0.0.1:$GLITCHTIP/$GT_PROJECT_ID"
      echo "export OBSERVABILITY_SIGNOZ_URL=http://127.0.0.1:$SIGNOZ"
      echo "export OBSERVABILITY_GLITCHTIP_URL=http://127.0.0.1:$GLITCHTIP"
      echo "export OBSERVABILITY_SIGNOZ_PUBLIC_URL=$(signoz_public_url)"
      echo "export OBSERVABILITY_GLITCHTIP_PUBLIC_URL=$(glitchtip_public_url)"
      echo "export OBSERVABILITY_SIGNOZ_API_KEY=$SIGNOZ_API_KEY"
      echo "export OBSERVABILITY_GLITCHTIP_TOKEN=$GT_TOKEN"
      echo "export OBSERVABILITY_GLITCHTIP_ORG=$OBS_GLITCHTIP_SLUG"
      if [ -n "${OBS_APP_ENV:-}" ]; then printf '%s\n' "$OBS_APP_ENV"; fi
    } > "$tmp"
  )
  mv "$tmp" "$ENV_FILE"
}

# ---------------------------------------------------------------------------
# Postgres (the project's own devenv cluster)
# ---------------------------------------------------------------------------

pg_port() {
  local file="$DEVENV_STATE/postgres/postgresql.conf" port=""
  [ -f "$file" ] && port="$(sed -n 's/^port = \([0-9]\+\).*/\1/p' "$file" | tail -n1)"
  echo "${port:-${PGPORT:-5432}}"
}

pg_admin() {
  psql -h "${PGHOST:-127.0.0.1}" -p "$(pg_port)" -U "${PGUSER:-$(id -un)}" -d postgres -v ON_ERROR_STOP=1 -qAt "$@"
}

ensure_postgres() {
  pg_isready -q -h "${PGHOST:-127.0.0.1}" -p "$(pg_port)" ||
    die "the project's Postgres is not reachable on port $(pg_port); run 'devenv up -d' first"
  # Always (re)set the password: the state dir can be wiped while the cluster stays.
  if [ -z "$(pg_admin -c "select 1 from pg_roles where rolname = '$GT_DB'")" ]; then
    pg_admin -c "create role $GT_DB login password '$GT_DB_PASSWORD'"
  else
    pg_admin -c "alter role $GT_DB login password '$GT_DB_PASSWORD'"
  fi
  if [ -z "$(pg_admin -c "select 1 from pg_database where datname = '$GT_DB'")" ]; then
    pg_admin -c "create database $GT_DB owner $GT_DB"
  fi
  # Needs a superuser on some servers; created here, where we hold one.
  PGOPTIONS='-c client_min_messages=warning' psql -h "${PGHOST:-127.0.0.1}" -p "$(pg_port)" -U "${PGUSER:-$(id -un)}" -d "$GT_DB" \
    -v ON_ERROR_STOP=1 -qAt -c 'create extension if not exists pg_trgm'
  # A reset of the cluster (rm -rf .devenv/state/postgres) leaves our markers
  # behind, so the database decides whether GlitchTip still needs initialising.
  if [ -z "$(psql -h "${PGHOST:-127.0.0.1}" -p "$(pg_port)" -U "${PGUSER:-$(id -un)}" -d "$GT_DB" -qAt -c "select to_regclass('public.django_migrations')")" ]; then
    rm -f "$MARKERS/glitchtip-initialized"
  fi
}

# ---------------------------------------------------------------------------
# The services
# ---------------------------------------------------------------------------

ch() { "$OBS_CLICKHOUSE/bin/clickhouse-client" --port "$CLICKHOUSE_TCP" "$@"; }

render() {
  # render TEMPLATE TARGET
  local args=() name
  for name in "${PORT_NAMES[@]}"; do
    args+=(-e "s#@$name@#${!name}#g")
  done
  sed "${args[@]}" -e "s#@DATA@#$DATA/clickhouse#g" -e "s#@CONF@#$OBS_CONFIG_DIR#g" "$1" > "$2"
}

start_clickhouse() {
  alive clickhouse && return 0
  log "starting ClickHouse"
  mkdir -p "$DATA/clickhouse"/{tmp,keeper_log,keeper_snap,user_files,format_schemas,user_scripts}
  install -m 0755 "$OBS_HISTOGRAM_QUANTILE/histogram-quantile" "$DATA/clickhouse/user_scripts/histogram-quantile"
  render "$OBS_CONFIG_DIR/clickhouse-config.xml" "$RUN/clickhouse.xml"
  CLICKHOUSE_WATCHDOG_ENABLE=0 launch clickhouse "${OBS_MEMMAX_CLICKHOUSE}M" \
    "$OBS_CLICKHOUSE/bin/clickhouse-server" --config-file="$RUN/clickhouse.xml"
}

migrate_clickhouse() {
  [ -f "$MARKERS/clickhouse-migrated" ] && return 0
  log "running the SigNoz schema migrations (about 3 minutes, once)"
  "$OBS_MIGRATOR/bin/signoz-schema-migrator" sync \
    --dsn="tcp://127.0.0.1:$CLICKHOUSE_TCP" --cluster-name=cluster --replication=false > "$LOGS/migrate-sync.log" 2>&1
  "$OBS_MIGRATOR/bin/signoz-schema-migrator" async \
    --dsn="tcp://127.0.0.1:$CLICKHOUSE_TCP" --cluster-name=cluster --replication=false > "$LOGS/migrate-async.log" 2>&1
  date > "$MARKERS/clickhouse-migrated"
}

start_collector() {
  alive collector && return 0
  log "starting the OTLP collector"
  render "$OBS_CONFIG_COLLECTOR" "$RUN/collector.yaml"
  # 128 MiB: the Go runtime collects toward it; 160 MiB left RSS near 205 MB when idle. The memory_limiter in
  # collector.yaml sits above this, so a burst is refused before the heap grows.
  GOMEMLIMIT=128MiB launch collector "${OBS_MEMMAX_COLLECTOR}M" \
    "$OBS_COLLECTOR/bin/signoz-otel-collector" --config="$RUN/collector.yaml" --copy-path="$RUN/collector-copy.yaml"
}

# SigNoz listens for OpAMP on a hard-coded 0.0.0.0:4320 (a Go const with no
# setting; a bind failure kills the whole server), so two stacks on one host cannot
# coexist. OpAMP is unused here. Each environment runs its own copy of the binary
# with the same-length string patched: loopback on IPv6 where the host has it,
# otherwise the wildcard address on this environment's own port.
signoz_binary() {
  local target="$RUN/signoz-opamp-$OPAMP" source="$OBS_SIGNOZ/bin/signoz" addr
  [ -x "$target" ] && { echo "$target"; return 0; }
  if [ "${OPAMP}" -lt 1024 ] || [ "${OPAMP}" -gt 9999 ]; then
    die "OBSERVABILITY_PORT_OPAMP must have four digits (got $OPAMP)"
  fi
  if grep -qs '00000000000000000000000000000001' /proc/net/if_inet6; then
    addr="$(printf '[::1]:%06d' "$OPAMP")"
  else
    addr="0.0.0.0:$OPAMP"
  fi
  grep -qa '0\.0\.0\.0:4320' "$source" || die "the SigNoz binary no longer holds the OpAMP address; update signoz_binary"
  rm -f "$RUN"/signoz-opamp-*
  LC_ALL=C sed "s/0\.0\.0\.0:4320/$addr/g" "$source" > "$target.tmp"
  chmod 0755 "$target.tmp"
  mv "$target.tmp" "$target"
  echo "$target"
}

start_signoz() {
  alive signoz && return 0
  log "starting SigNoz"
  mkdir -p "$DATA/signoz"
  local binary
  binary="$(signoz_binary)"
  (
    export SIGNOZ_APISERVER_ADDRESS="127.0.0.1:$SIGNOZ"
    export SIGNOZ_TELEMETRYSTORE_CLICKHOUSE_DSN="tcp://127.0.0.1:$CLICKHOUSE_TCP"
    export SIGNOZ_TELEMETRYSTORE_CLICKHOUSE_CLUSTER=cluster
    export SIGNOZ_TELEMETRYSTORE_MAX__OPEN__CONNS=8
    export SIGNOZ_TELEMETRYSTORE_MAX__IDLE__CONNS=4
    export SIGNOZ_SQLSTORE_PROVIDER=sqlite
    export SIGNOZ_SQLSTORE_SQLITE_PATH="$DATA/signoz/signoz.db"
    export SIGNOZ_SQLSTORE_MAX__OPEN__CONNS=8
    export SIGNOZ_WEB_DIRECTORY="$OBS_SIGNOZ/web"
    export SIGNOZ_INSTRUMENTATION_METRICS_ENABLED=false
    export SIGNOZ_PPROF_ENABLED=false
    export SIGNOZ_ANALYTICS_ENABLED=false
    export SIGNOZ_STATSREPORTER_ENABLED=false
    export SIGNOZ_VERSION_BANNER_ENABLED=false
    export SIGNOZ_CACHE_MEMORY_NUM__COUNTERS=10000
    export SIGNOZ_CACHE_MEMORY_MAX__COST=16777216
    export SIGNOZ_PROMETHEUS_ACTIVE__QUERY__TRACKER_ENABLED=false
    SIGNOZ_ALERTMANAGER_SIGNOZ_EXTERNAL__URL="$(signoz_public_url)"; export SIGNOZ_ALERTMANAGER_SIGNOZ_EXTERNAL__URL
    SIGNOZ_GLOBAL_EXTERNAL__URL="$(signoz_public_url)"; export SIGNOZ_GLOBAL_EXTERNAL__URL
    export SIGNOZ_TOKENIZER_JWT_SECRET="$JWT_SECRET"
    export SIGNOZ_USER_ROOT_ENABLED=true
    export SIGNOZ_USER_ROOT_EMAIL="$OBS_ROOT_EMAIL"
    export SIGNOZ_USER_ROOT_PASSWORD="$UI_PASSWORD"
    export SIGNOZ_USER_ROOT_ORG_NAME="$OBS_GLITCHTIP_SLUG"
    export SIGNOZ_FLAGGER_CONFIG_BOOLEAN_USE__SPAN__METRICS="$OBS_SPAN_METRICS"
    export GOMEMLIMIT=120MiB
    cd "$RUN"
    launch signoz "${OBS_MEMMAX_SIGNOZ}M" "$binary" server
  )
}

glitchtip_env() {
  DATABASE_URL="postgres://$GT_DB:$GT_DB_PASSWORD@127.0.0.1:$(pg_port)/$GT_DB"
  export DATABASE_URL
  export SECRET_KEY="$SECRET_KEY"
  GLITCHTIP_DOMAIN="$(glitchtip_public_url)"; export GLITCHTIP_DOMAIN
  CSRF_TRUSTED_ORIGINS="$(glitchtip_public_url)"; export CSRF_TRUSTED_ORIGINS
  export VALKEY_URL=""
  export GLITCHTIP_EMBED_WORKER=true
  export GLITCHTIP_ENABLE_UPTIME=false
  export GLITCHTIP_ENABLE_LOGS=false
  export GLITCHTIP_RETENTION_DAYS="$OBS_RETENTION_DAYS"
  export ENABLE_USER_REGISTRATION=false
  export GRANIAN_WORKERS=1
  export GRANIAN_HOST=127.0.0.1
  export GRANIAN_PORT="$GLITCHTIP"
  export GRANIAN_LOG_LEVEL=warning
  export MALLOC_ARENA_MAX=2
  export MALLOC_MMAP_THRESHOLD_=65536
  export MALLOC_TRIM_THRESHOLD_=65536
  export EMAIL_URL=consolemail://
  export PYTHONDONTWRITEBYTECODE=1
  export DJANGO_SETTINGS_MODULE=observability_settings
  export SKIP_INIT=true
  # A project's Python toolchain (a devenv venv) must not leak into GlitchTip's imports.
  unset PYTHONPATH PYTHONHOME VIRTUAL_ENV
  # Nor the app's DSN, which a shell that already ran `up` exports: GlitchTip reads
  # SENTRY_DSN for its own error reporting and would report itself into the app's project.
  unset SENTRY_DSN SENTRY_FRONTEND_DSN
  # shellcheck disable=SC1090
  . "$OBS_GLITCHTIP_PYTHONPATH"
  export PYTHONPATH="$OBS_CONFIG_DIR:$PYTHONPATH"
  export PATH="$OBS_GLITCHTIP_PYTHON/bin:$OBS_GRANIAN/bin:$PATH"
}

init_glitchtip() {
  [ -f "$MARKERS/glitchtip-initialized" ] && return 0
  log "initialising GlitchTip's database (once)"
  (
    glitchtip_env
    cd "$OBS_GLITCHTIP/lib/glitchtip"
    {
      python manage.py migrate --no-input --skip-checks
      python manage.py maintain_partitions
      python manage.py createcachetable
      OBS_GT_EMAIL="$OBS_ROOT_EMAIL" OBS_GT_PASSWORD="$UI_PASSWORD" OBS_GT_TOKEN="$GT_TOKEN" \
        OBS_GT_PUBLIC_KEY="$GT_PUBLIC_KEY" OBS_GT_SLUG="$OBS_GLITCHTIP_SLUG" \
        python manage.py shell -c "exec(open('$OBS_CONFIG_DIR/glitchtip_provision.py').read())"
    } > "$LOGS/glitchtip-init.log" 2>&1
  )
  local result
  result="$(sed -n 's/^OBS_RESULT //p' "$LOGS/glitchtip-init.log" | tail -n1)"
  [ -n "$result" ] || die "GlitchTip provisioning failed; see $LOGS/glitchtip-init.log"
  GT_PROJECT_ID="$(echo "$result" | jq -r .project_id)"
  echo "$GT_PROJECT_ID" > "$MARKERS/glitchtip-project-id"
  date > "$MARKERS/glitchtip-initialized"
}

start_glitchtip() {
  alive glitchtip && return 0
  log "starting GlitchTip"
  (
    glitchtip_env
    cd "$OBS_GLITCHTIP/lib/glitchtip"
    launch glitchtip "${OBS_MEMMAX_GLITCHTIP}M" sh ./bin/run-all-in-one.sh
  )
}

signoz_api() {
  # signoz_api METHOD PATH [BODY] (with $SIGNOZ_TOKEN set)
  local method="$1" path="$2" body="${3:-}"
  local args=(-sf -X "$method" -H "Authorization: Bearer $SIGNOZ_TOKEN" -H 'content-type: application/json')
  [ -n "$body" ] && args+=(-d "$body")
  curl "${args[@]}" "http://127.0.0.1:$SIGNOZ$path"
}

signoz_login() {
  local org
  org="$(curl -sf "http://127.0.0.1:$SIGNOZ/api/v2/sessions/context?email=$OBS_ROOT_EMAIL&ref=http://127.0.0.1:$SIGNOZ" | jq -r '.data.orgs[0].id // empty')" || return 1
  [ -n "$org" ] || return 1
  SIGNOZ_TOKEN="$(curl -sf -X POST "http://127.0.0.1:$SIGNOZ/api/v2/sessions/email_password" -H 'content-type: application/json' \
    -d "$(jq -cn --arg e "$OBS_ROOT_EMAIL" --arg p "$UI_PASSWORD" --arg o "$org" '{email:$e,password:$p,orgId:$o}')" | jq -r '.data.accessToken // empty')" || return 1
  [ -n "$SIGNOZ_TOKEN" ]
}

provision_signoz() {
  local ttl_marker="$MARKERS/signoz-retention-$OBS_RETENTION_DAYS"
  [ -n "$SIGNOZ_API_KEY" ] && [ -f "$ttl_marker" ] && return 0
  local i
  for i in $(seq 1 120); do
    signoz_login && break
    sleep 0.5
  done
  [ -n "${SIGNOZ_TOKEN:-}" ] || die "could not sign in to SigNoz as the root user; see $LOGS/signoz.log"

  if [ -z "$SIGNOZ_API_KEY" ]; then
    log "creating the SigNoz API key"
    local sa rid key
    sa="$(signoz_api GET /api/v1/service_accounts | jq -r '.data[] | select(.name == "observability") | .id' | head -n1)"
    if [ -z "$sa" ]; then
      sa="$(signoz_api POST /api/v1/service_accounts '{"name":"observability"}' | jq -r .data.id)"
      rid="$(signoz_api GET /api/v1/roles | jq -r '.data[] | select(.name == "signoz-admin") | .id')"
      signoz_api POST /api/v1/service_account_roles "$(jq -cn --arg s "$sa" --arg r "$rid" '{serviceAccountId:$s,roleId:$r}')" > /dev/null
    fi
    key="$(signoz_api POST "/api/v1/service_accounts/$sa/keys" "$(jq -cn --arg n "observability-$(date +%s)" '{name:$n,expiresAt:0}')" | jq -r .data.key)"
    (umask 077; printf '%s' "$key" > "$SECRETS/signoz-api-key")
    SIGNOZ_API_KEY="$key"
  fi

  if [ ! -f "$ttl_marker" ]; then
    log "setting retention to $OBS_RETENTION_DAYS days"
    local hours=$((OBS_RETENTION_DAYS * 24))
    signoz_api POST "/api/v1/settings/ttl?type=traces&duration=${hours}h" > /dev/null
    signoz_api POST "/api/v1/settings/ttl?type=metrics&duration=${hours}h" > /dev/null
    signoz_api POST /api/v2/settings/ttl "$(jq -cn --argjson d "$OBS_RETENTION_DAYS" '{type:"logs",defaultTTLDays:$d,coldStorageVolume:"",coldStorageDurationDays:0,ttlConditions:[]}')" > /dev/null
    date > "$ttl_marker"
  fi
}

# ---------------------------------------------------------------------------
# Dashboards, alerts and saved views (OBS_PROVISION_DIRS)
# ---------------------------------------------------------------------------
# Each directory may hold dashboards/, alerts/ and views/ of JSON files in the shapes
# SigNoz's v2 API takes. Every `up` makes SigNoz match them, by name: a missing item is
# created, one whose file changed since it was last provisioned is replaced, and the
# rest are left alone, so `up` twice creates nothing twice and edits made in the UI
# survive until the file itself changes.

# signoz_key_api METHOD PATH [BODY]: through the stack's API key. Prints the body;
# fails on a non-2xx status.
signoz_key_api() {
  local method="$1" path="$2" body="${3:-}" out status
  local args=(-s -X "$method" -H "SIGNOZ-API-KEY: $SIGNOZ_API_KEY" -H 'content-type: application/json' -w '\n%{http_code}')
  [ -n "$body" ] && args+=(--data-binary "$body")
  out="$(curl "${args[@]}" "http://127.0.0.1:$SIGNOZ$path")" || return 1
  status="${out##*$'\n'}"
  printf '%s' "${out%$'\n'*}"
  [ "${status:0:1}" = 2 ]
}

urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

# A dashboard file without a name (SigNoz's own templates use generateName) is named
# after the file, which keeps it stable across runs.
provision_body() {
  local kind="$1" file="$2" base
  base="$(basename "$file" .json)"
  case "$kind" in
    dashboards) jq -c --arg n "$base" 'del(.generateName) | .name //= $n' "$file" ;;
    *) jq -c . "$file" ;;
  esac
}

provision_name() {
  case "$1" in
    dashboards | views) jq -r .name <<< "$2" ;;
    alerts) jq -r .alert <<< "$2" ;;
  esac
}

provision_lookup() {
  local kind="$1" name="$2" source
  case "$kind" in
    dashboards)
      # The list's `name` filter matches the display name, so match the machine name here.
      signoz_key_api GET "/api/v2/dashboards?limit=200" |
        jq -r --arg n "$name" '[.data.dashboards[]? | select(.name == $n) | .id][0] // empty' ;;
    alerts)
      signoz_key_api GET /api/v2/rules | jq -r --arg n "$name" '[.data[]? | select(.alert == $n) | .id][0] // empty' ;;
    views)
      source="${3:-traces}"
      signoz_key_api GET "/api/v2/saved_views?source=$source&name=$(urlencode "$name")" | jq -r '.data[0].id // empty' ;;
  esac
}

provision_path() {
  case "$1" in
    dashboards) echo /api/v2/dashboards ;;
    alerts) echo /api/v2/rules ;;
    views) echo /api/v2/saved_views ;;
  esac
}

provision_item() {
  local kind="$1" file="$2" body name id hash marker
  body="$(provision_body "$kind" "$file")" || { log "skipping $file: not JSON"; return 0; }
  name="$(provision_name "$kind" "$body")"
  [ -n "$name" ] && [ "$name" != null ] || { log "skipping $file: no name"; return 0; }
  hash="$(printf '%s' "$body" | sha256sum | cut -c1-16)"
  marker="$MARKERS/provisioned/$kind-$(printf '%s' "$name" | sha256sum | cut -c1-16)"
  id="$(provision_lookup "$kind" "$name" "$(jq -r '.source // empty' <<< "$body")")" || {
    log "could not look up $kind '$name'"
    return 1
  }
  if [ -z "$id" ]; then
    signoz_key_api POST "$(provision_path "$kind")" "$body" > /dev/null || {
      log "could not create $kind '$name' from $(basename "$file")"
      return 1
    }
    log "created $kind: $name"
  elif [ "$(cat "$marker" 2>/dev/null)" != "$hash" ]; then
    # A saved view's machine name is fixed at creation and not part of its update.
    local update="$body"
    [ "$kind" = views ] && update="$(jq -c 'del(.name)' <<< "$body")"
    signoz_key_api PUT "$(provision_path "$kind")/$id" "$update" > /dev/null || {
      log "could not update $kind '$name' from $(basename "$file")"
      return 1
    }
    log "updated $kind: $name"
  fi
  echo "$hash" > "$marker"
}

provision_content() {
  [ -n "${OBS_PROVISION_DIRS:-}" ] && [ -n "$SIGNOZ_API_KEY" ] || return 0
  mkdir -p "$MARKERS/provisioned"
  local dir kind file failed=0 dirs
  IFS=: read -r -a dirs <<< "$OBS_PROVISION_DIRS"
  for kind in dashboards alerts views; do
    for dir in "${dirs[@]}"; do
      [ -d "$dir/$kind" ] || continue
      for file in "$dir/$kind"/*.json; do
        [ -f "$file" ] || continue
        provision_item "$kind" "$file" || failed=1
      done
    done
  done
  [ "$failed" = 0 ] || log "some SigNoz content was not provisioned; the stack is up regardless"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

prepare_dirs() { mkdir -p "$RUN" "$LOGS" "$DATA" "$SECRETS" "$MARKERS"; chmod 700 "$SECRETS"; }

cmd_prepare() {
  prepare_dirs
  allocate_ports
  ensure_secrets
  write_env
  log "env written to $ENV_FILE (nothing started)"
}

cmd_up() {
  prepare_dirs
  exec 9> "$ROOT/lock"
  flock -n 9 || die "another 'observability up' is already running"
  local t0=$SECONDS
  allocate_ports
  ensure_secrets
  write_env                 # first, so an app that starts while this runs picks it up
  ensure_postgres           # before anything slow, so a missing database fails fast
  bring_up clickhouse ClickHouse 60 ch -q 'select 1'
  migrate_clickhouse
  start_rest
  provision_signoz
  provision_content
  init_glitchtip
  bring_up glitchtip GlitchTip 120 curl -sf "http://127.0.0.1:$GLITCHTIP/_health/"
  # Give a dependent a moment to fail on its first writes, then check them all; a
  # service that died is started again once before up fails.
  sleep "${OBSERVABILITY_SETTLE_SECONDS:-5}"
  if ! verify_running; then
    log "a service exited after starting; starting it again"
    bring_up clickhouse ClickHouse 60 ch -q 'select 1'
    start_rest
    bring_up glitchtip GlitchTip 120 curl -sf "http://127.0.0.1:$GLITCHTIP/_health/"
    sleep "${OBSERVABILITY_SETTLE_SECONDS:-5}"
    verify_running || die "the stack did not stay up; see $LOGS ($(for n in "${SERVICES[@]}"; do alive "$n" || printf '%s ' "$n"; done)exited)"
  fi
  write_env
  log "ready in $((SECONDS - t0))s"
  cmd_urls
}

start_rest() {
  bring_up collector "the collector" 60 curl -sf "http://127.0.0.1:$COLLECTOR_HEALTH/"
  bring_up signoz SigNoz 60 curl -sf "http://127.0.0.1:$SIGNOZ/api/v1/health"
}

stop_service() {
  local name="$1"
  alive "$name" || { rm -f "$(record_file "$name")"; return 0; }
  local pid children=() c i
  pid="$(record_pid "$name")"
  while read -r c; do
    children+=("$c $(proc_start "$c")")
  done < <(descendants "$pid")
  log "stopping $name (pid $pid)"
  kill -TERM "$pid" 2>/dev/null || true
  for i in $(seq 1 120); do
    alive "$name" || break
    sleep 0.5
  done
  if alive "$name"; then
    log "$name did not exit; sending SIGKILL to pid $pid"
    kill -KILL "$pid" 2>/dev/null || true
    sleep 0.5
  fi
  # Workers we saw before the signal, identified the same way as the parent.
  local entry cpid cstart
  for entry in ${children[@]+"${children[@]}"}; do
    cpid="${entry%% *}" cstart="${entry##* }"
    if [ -d "/proc/$cpid" ] && [ "$(proc_start "$cpid")" = "$cstart" ]; then
      kill -TERM "$cpid" 2>/dev/null || true
    fi
  done
  rm -f "$(record_file "$name")"
  if have_user_scopes; then
    systemctl --user reset-failed "$(unit_name "$name").scope" >/dev/null 2>&1 || true
  fi
}

cmd_down() {
  mkdir -p "$RUN"
  local i
  for ((i=${#SERVICES[@]}-1; i>=0; i--)); do
    stop_service "${SERVICES[$i]}"
  done
  rm -f "$ENV_FILE"
  log "stopped; data kept in $DATA"
}

mem_of() {
  # mem_of PID... prints "rss pss anon" in MB, summed
  local pid
  for pid in "$@"; do
    [ -r "/proc/$pid/smaps_rollup" ] && cat "/proc/$pid/smaps_rollup" 2>/dev/null
  done | awk '/^Rss:/{r+=$2} /^Pss:/{p+=$2} /^Anonymous:/{a+=$2} END{printf "%d %d %d\n", r/1024, p/1024, a/1024}'
}

service_budget() {
  case "$1" in
    clickhouse) echo "$OBS_BUDGET_CLICKHOUSE" ;;
    collector) echo "$OBS_BUDGET_COLLECTOR" ;;
    signoz) echo "$OBS_BUDGET_SIGNOZ" ;;
    glitchtip) echo "$OBS_BUDGET_GLITCHTIP" ;;
  esac
}

cmd_status() {
  local name pid rss pss anon budget state total_rss=0 total_pss=0 total_anon=0 over="" stopped=""
  printf '%-22s %8s %8s %8s %8s %8s  %s\n' SERVICE PID RSS_MB PSS_MB ANON_MB BUDGET STATE
  for name in "${SERVICES[@]}"; do
    budget="$(service_budget "$name")"
    if alive "$name"; then
      pid="$(record_pid "$name")"
      # shellcheck disable=SC2046
      read -r rss pss anon < <(mem_of "$pid" $(descendants "$pid"))
      state=ok
      if [ "$rss" -gt "$budget" ]; then state="OVER RSS BUDGET"; over=1; fi
      printf '%-22s %8s %8s %8s %8s %8s  %s\n' "$name" "$pid" "$rss" "$pss" "$anon" "$budget" "$state"
      total_rss=$((total_rss + rss)) total_pss=$((total_pss + pss)) total_anon=$((total_anon + anon))
    else
      printf '%-22s %8s %8s %8s %8s %8s  %s\n' "$name" - - - - "$budget" stopped
      stopped=1
    fi
  done

  local backends="" bpid
  if [ -z "$stopped" ] && [ -f "$PORTS_FILE" ]; then
    backends="$(pg_admin -c "select pid from pg_stat_activity where datname = '$GT_DB'" 2>/dev/null || true)"
  fi
  if [ -n "$backends" ]; then
    local bpids=()
    for bpid in $backends; do bpids+=("$bpid"); done
    read -r rss pss anon < <(mem_of "${bpids[@]}")
    printf '%-22s %8s %8s %8s %8s %8s  %s\n' "postgres (glitchtip)" "${#bpids[@]}bk" "$rss" "$pss" "$anon" - "shared cluster; PSS is the fair figure"
    total_pss=$((total_pss + pss)) total_anon=$((total_anon + anon))
  fi

  printf '%-22s %8s %8s %8s %8s %8s\n' TOTAL "" "$total_rss" "$total_pss" "$total_anon" "$OBS_BUDGET_TOTAL"
  printf 'budget: RSS %s of %s MB, PSS %s of %s MB\n' "$total_rss" "$OBS_BUDGET_TOTAL" "$total_pss" "$OBS_BUDGET_TOTAL"
  if [ "$total_rss" -gt "$OBS_BUDGET_TOTAL" ] || [ "$total_pss" -gt "$OBS_BUDGET_TOTAL" ]; then
    over=1
    echo "OVER TOTAL BUDGET"
  fi
  if have_user_scopes; then echo "cgroup: systemd user scopes"; else echo "cgroup: shared (no user systemd; ClickHouse uses memory_worker_use_cgroup=false)"; fi
  [ -z "$stopped" ] || return 3
  [ -z "$over" ] || return 2
}

load_ports() {
  [ -f "$PORTS_FILE" ] || die "not started yet; run 'observability up'"
  # shellcheck disable=SC1090
  . "$PORTS_FILE"
}

cmd_urls() {
  load_ports
  ensure_secrets
  echo "SigNoz       $(signoz_public_url)"
  echo "GlitchTip    $(glitchtip_public_url)"
  echo "Sign in      $OBS_ROOT_EMAIL  /  $UI_PASSWORD   (both tools)"
  echo "OTLP (HTTP)  http://127.0.0.1:$OTLP_HTTP"
  echo "DSN          http://${GT_PUBLIC_KEY//-/}@127.0.0.1:$GLITCHTIP/$GT_PROJECT_ID"
  echo "Env file     $ENV_FILE"
}

cmd_provision() {
  load_ports
  ensure_secrets
  [ -n "$SIGNOZ_API_KEY" ] || die "no SigNoz API key yet; run \`observability up\` first"
  curl -sf "http://127.0.0.1:$SIGNOZ/api/v1/health" > /dev/null || die "SigNoz is not answering on $SIGNOZ; run \`observability up\`"
  provision_content
}

# ---------------------------------------------------------------------------
# Reading traces: slow, trace, queries
#
# Read-only. They query SigNoz's span table through the same ClickHouse client and port
# `up` uses, so the caller needs to know neither. Output is plain text; --json prints the
# same data as JSON. Only span names, durations, SQL text and the ui.* / enduser.name
# attributes are read: never the environment, never a secret.
# ---------------------------------------------------------------------------

SPANS="signoz_traces.distributed_signoz_index_v3"
# LiveView lifecycle spans: Module.mount, Module.handle_params, Module.handle_event[#name], and lv.connect.
LV_RE='(\\.(mount|handle_params)|\\.handle_event(#.*)?| lv\\.connect)$'

# The topmost span of a trace has no parent, or a parent that is not in the trace (a
# LiveView event continues a browser-side parent that is never exported).
ROOTISH="(parent_span_id = '' or parent_span_id not in (select span_id from $SPANS where trace_id in (%s)))"

trace_ch() {
  load_ports
  port_busy "$CLICKHOUSE_TCP" || die "ClickHouse is not answering on $CLICKHOUSE_TCP; run 'observability up'"
  ch --output_format_json_quote_64bit_integers 0 "$@"
}

set_trace_opt() {
  case "$1" in
    --since) SINCE="$2" ;;
    --limit) LIMIT="$2" ;;
    --threshold) THRESHOLD="$2" ;;
    --by) BY="$2" ;;
  esac
}

# Sets SINCE, LIMIT, THRESHOLD, FULL, AS_JSON and POSITIONAL from the arguments.
parse_trace_opts() {
  SINCE=3h BY=name LIMIT="" THRESHOLD=20 FULL="" AS_JSON="" POSITIONAL=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --since|--limit|--threshold|--by)
        [ $# -ge 2 ] || die "$1 needs a value"
        set_trace_opt "$1" "$2"
        shift 2
        ;;
      --since=*|--limit=*|--threshold=*|--by=*)
        set_trace_opt "${1%%=*}" "${1#*=}"
        shift
        ;;
      --full) FULL=1; shift ;;
      --json) AS_JSON=1; shift ;;
      -*) die "unknown option '$1'" ;;
      *) POSITIONAL+=("$1"); shift ;;
    esac
  done
  [[ "$SINCE" =~ ^([0-9]+)([smhd])$ ]] || die "--since takes a number and a unit (s, m, h or d), like 3h; got '$SINCE'"
  case "${BASH_REMATCH[2]}" in
    s) SINCE_SECONDS="${BASH_REMATCH[1]}" ;;
    m) SINCE_SECONDS=$((BASH_REMATCH[1] * 60)) ;;
    h) SINCE_SECONDS=$((BASH_REMATCH[1] * 3600)) ;;
    d) SINCE_SECONDS=$((BASH_REMATCH[1] * 86400)) ;;
  esac
  [[ "${LIMIT:-1}" =~ ^[0-9]+$ ]] && [ "${LIMIT:-1}" -gt 0 ] || die "--limit takes a positive number; got '$LIMIT'"
  case "$BY" in name|page) ;; *) die "--by takes name or page; got '$BY'" ;; esac
  [[ "$THRESHOLD" =~ ^[0-9]+$ ]] && [ "$THRESHOLD" -gt 0 ] || die "--threshold takes a positive number; got '$THRESHOLD'"
}

# A table from tab-separated lines on stdin; the first line is the header.
text_table() { column -t -s $'\t' | sed 's/^/  /'; }

# Per span name: count, p50 and max duration, and the trace of the slowest one.
slow_by_name() {
  trace_ch -q "
    select name, count() as spans,
      round(quantile(0.5)(duration_nano) / 1e6, 1) as p50_ms,
      round(max(duration_nano) / 1e6, 1) as max_ms,
      argMax(trace_id, duration_nano) as trace_id,
      argMax(attributes_string['ui.surface.id'], duration_nano) as surface,
      argMax(concat(attributes_string['ui.action.resource'], ' ', attributes_string['ui.action.name']), duration_nano) as action
    from $SPANS
    where timestamp > now() - interval $SINCE_SECONDS second and $1
    group by name
    order by max(duration_nano) desc
    limit $LIMIT
    format JSONEachRow" | jq -s '.'
}

print_slow() {
  echo "$1"
  if [ "$(jq length <<<"$2")" -eq 0 ]; then echo "  (no spans in the window)"; return 0; fi
  jq -r '["SPAN", "COUNT", "P50_MS", "MAX_MS", "TRACE_ID", "SURFACE_AND_ACTION"],
    (.[] | [.name, .spans, .p50_ms, .max_ms, .trace_id,
            ((.surface + " " + (.action | gsub("^ +| +$"; ""))) | gsub("^ +| +$"; "") | if . == "" then "-" else . end)])
    | @tsv' <<<"$2" | text_table
}

# Page keys. An HTTP root is "GET /route", a connect span "/route lv.connect"; LiveView
# lifecycle spans carry the module, and an event the surface id of its ui.* attributes.
HTTP_RE='^[A-Z]+ /'
read -r -d '' PAGE_SQL <<'SQL' || true
multiIf(
    parent_span_id = '' and match(name, '^[A-Z]+ /'), replaceRegexpOne(name, '^[A-Z]+ ', ''),
    match(name, ' lv\\.connect$'), replaceRegexpOne(name, ' lv\\.connect$', ''),
    attributes_string['ui.surface.id'] != '', attributes_string['ui.surface.id'],
    replaceRegexpOne(name, '\\.(mount|handle_params|handle_event.*)$', ''))
SQL
read -r -d '' KIND_SQL <<'SQL' || true
multiIf(
    parent_span_id = '' and match(name, '^[A-Z]+ /'), 'http',
    match(name, ' lv\\.connect$'), 'connect',
    match(name, '\\.mount$'), 'mount',
    match(name, '\\.handle_params$'), 'params',
    'event')
SQL

slow_by_page() {
  trace_ch -q "
    select $PAGE_SQL as page, $KIND_SQL as kind, count() as spans,
      round(quantile(0.5)(duration_nano) / 1e6, 1) as p50_ms,
      round(quantile(0.95)(duration_nano) / 1e6, 1) as p95_ms,
      round(max(duration_nano) / 1e6, 1) as max_ms,
      argMax(trace_id, duration_nano) as trace_id
    from $SPANS
    where timestamp > now() - interval $SINCE_SECONDS second
      and ((parent_span_id = '' and match(name, '$HTTP_RE')) or match(name, '$LV_RE'))
    group by page, kind
    order by max(duration_nano) desc
    limit $LIMIT
    format JSONEachRow" | jq -s '.'
}

cmd_slow() {
  parse_trace_opts "$@"
  [ "${#POSITIONAL[@]}" -eq 0 ] || die "slow takes no arguments; got '${POSITIONAL[0]}'"
  LIMIT="${LIMIT:-10}"
  local roots lv pages
  if [ "$BY" = page ]; then
    pages="$(slow_by_page)"
    if [ -n "$AS_JSON" ]; then
      jq -n --arg since "$SINCE" --argjson pages "$pages" '{since: $since, by: "page", pages: $pages}'
      return 0
    fi
    echo "Pages, last $SINCE (HTTP request, LiveView connect, mount, params and events per route or surface; worst case first):"
    if [ "$(jq length <<<"$pages")" -eq 0 ]; then echo "  (no spans in the window)"; return 0; fi
    jq -r '["PAGE", "KIND", "COUNT", "P50_MS", "P95_MS", "MAX_MS", "WORST_TRACE"],
      (.[] | [.page, .kind, .spans, .p50_ms, .p95_ms, .max_ms, .trace_id]) | @tsv' <<<"$pages" | text_table
    echo
    echo "Next: observability trace <WORST_TRACE>"
    return 0
  fi
  roots="$(slow_by_name "parent_span_id = ''")"
  lv="$(slow_by_name "match(name, '$LV_RE')")"
  if [ -n "$AS_JSON" ]; then
    jq -n --arg since "$SINCE" --argjson roots "$roots" --argjson liveview "$lv" '{since: $since, roots: $roots, liveview: $liveview}'
    return 0
  fi
  print_slow "Slowest root spans, last $SINCE (by worst case):" "$roots"
  echo
  print_slow "Slowest LiveView spans (mount, handle_params, handle_event, lv.connect), last $SINCE:" "$lv"
  echo
  echo "Next: observability trace <TRACE_ID>"
}

# The spans of one trace as a JSON array.
trace_spans() {
  trace_ch -q "
    select span_id, parent_span_id, name, round(duration_nano / 1e6, 2) as ms, has_error,
      attributes_string['ui.surface.id'] as surface,
      attributes_string['ui.action.resource'] as action_resource,
      attributes_string['ui.action.name'] as action_name,
      attributes_string['enduser.name'] as user
    from $SPANS
    where trace_id = '$1'
    order by timestamp
    format JSONEachRow" | jq -s '.'
}

# Reads the span array on stdin; prints the by-name rollup (heaviest first).
# shellcheck disable=SC2016
ROLLUP_JQ='
  group_by(.name)
  | map({name: .[0].name, count: length,
         total_ms: ((map(.ms) | add) * 10 | round / 10),
         max_ms: (map(.ms) | max),
         likely_n_plus_1: (length >= $threshold)})
  | sort_by(-.total_ms)'

# Reads the span array on stdin; prints the indented tree. Spans that share a parent and a
# name are folded into one line (xN, total, max) with the first one expanded, unless --full.
# shellcheck disable=SC2016
TREE_JQ='
  def indent($n): reduce range(0; $n) as $_ (""; . + " ");
  def groups:
    reduce .[] as $c ({o: [], m: {}};
      if .m[$c.name] then .m[$c.name] += [$c] else .o += [$c.name] | .m[$c.name] = [$c] end)
    | .m as $m | [.o[] | $m[.]];
  def node($kids; $d; $full):
    .[0] as $f
    | (indent($d * 2) + $f.name
       + (if length > 1
          then "  x\(length)  total \((map(.ms) | add) * 10 | round / 10) ms  max \(map(.ms) | max) ms  (first expanded)"
          else "  \($f.ms) ms" end)
       + (if any(.[]; .has_error) then "  [error]" else "" end)),
      (($kids[$f.span_id] // []) | (if $full then map([.]) else groups end) | .[] | node($kids; $d + 1; $full));
  . as $all
  | (reduce $all[] as $s ({}; .[$s.span_id] = true)) as $present
  | (reduce $all[] as $s ({}; .[$s.parent_span_id] += [$s])) as $kids
  | [$all[] | select(.parent_span_id == "" or ($present[.parent_span_id] | not))] as $roots
  | $roots | (if $full then map([.]) else groups end) | .[] | node($kids; 0; $full)'

# shellcheck disable=SC2016
ROLLUP_TEXT_JQ='
  (to_entries | map(select(.key < $limit or .value.likely_n_plus_1)) | map(.value)) as $shown
  | ["SPAN", "COUNT", "TOTAL_MS", "MAX_MS", "FLAG"],
    ($shown[] | [.name, .count, .total_ms, .max_ms, (if .likely_n_plus_1 then "likely N+1" else "-" end)])
  | @tsv'

# shellcheck disable=SC2016
ROOT_JQ='
  (reduce .[] as $s ({}; .[$s.span_id] = true)) as $present
  | [.[] | select(.parent_span_id == "" or ($present[.parent_span_id] | not))]
  | max_by(.ms)'

cmd_trace() {
  parse_trace_opts "$@"
  [ "${#POSITIONAL[@]}" -eq 1 ] || die "usage: observability trace <trace_id> [--threshold N] [--full] [--json]"
  local id="${POSITIONAL[0]}" spans root
  [[ "$id" =~ ^[0-9a-fA-F]{32}$ ]] || die "a trace id is 32 hex digits; got '$id'"
  id="${id,,}"
  LIMIT="${LIMIT:-15}"
  spans="$(trace_spans "$id")"
  [ "$(jq length <<<"$spans")" -gt 0 ] || die "no spans for trace $id (wrong id, or older than the retention window)"
  root="$(jq -c "$ROOT_JQ" <<<"$spans")"
  if [ -n "$AS_JSON" ]; then
    jq --arg id "$id" --argjson threshold "$THRESHOLD" --argjson root "$root" \
      "{trace_id: \$id, span_count: length, root: \$root, rollup: ($ROLLUP_JQ), spans: .}" <<<"$spans"
    return 0
  fi
  jq -r --arg id "$id" --argjson n "$(jq length <<<"$spans")" '
    "Trace \($id)\n  \($n) spans; root: \(.name), \(.ms) ms"
    + (if .surface != "" then "\n  surface: \(.surface)" else "" end)
    + (if .action_name != "" then "\n  action: \(.action_resource) \(.action_name)" else "" end)
    + (if .user != "" then "\n  user: \(.user)" else "" end)' <<<"$root"
  echo
  echo "Span tree (ms are each span's own wall time, children included):"
  jq -r --argjson full "${FULL:-false}" "$TREE_JQ" <<<"$spans" | sed 's/^/  /'
  echo
  echo "By span name (heaviest first; names repeated at least $THRESHOLD times are flagged):"
  jq -r --argjson threshold "$THRESHOLD" --argjson limit "$LIMIT" "($ROLLUP_JQ) | $ROLLUP_TEXT_JQ" <<<"$spans" | text_table
  local flagged
  flagged="$(jq --argjson threshold "$THRESHOLD" "$ROLLUP_JQ | map(select(.likely_n_plus_1)) | length" <<<"$spans")"
  if [ "$flagged" -gt 0 ]; then
    echo
    echo "$flagged span name(s) repeat at least $THRESHOLD times in this one trace: batch them (one call over many ids) and re-measure."
  fi
}

cmd_queries() {
  parse_trace_opts "$@"
  [ "${#POSITIONAL[@]}" -eq 0 ] || die "queries takes no arguments; got '${POSITIONAL[0]}'"
  LIMIT="${LIMIT:-10}"
  local queries ids roots
  queries="$(trace_ch -q "
    select trace_id, name, round(duration_nano / 1e6, 1) as ms,
      attributes_string['db.statement'] as statement
    from $SPANS
    where timestamp > now() - interval $SINCE_SECONDS second
      and (name like '%repo.query%' or attributes_string['db.statement'] != '')
    order by duration_nano desc
    limit $LIMIT
    format JSONEachRow" | jq -s '.')"
  ids="$(jq -r '[.[].trace_id] | unique | map("'"'"'" + . + "'"'"'") | join(",")' <<<"$queries")"
  roots='[]'
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2059
    roots="$(trace_ch -q "
      select trace_id, argMax(name, duration_nano) as root_name,
        argMax(attributes_string['ui.surface.id'], duration_nano) as surface,
        argMax(attributes_string['ui.action.resource'], duration_nano) as action_resource,
        argMax(attributes_string['ui.action.name'], duration_nano) as action_name,
        argMax(attributes_string['enduser.name'], duration_nano) as user
      from $SPANS
      where trace_id in ($ids) and $(printf "$ROOTISH" "$ids")
      group by trace_id
      format JSONEachRow" | jq -s '.')"
  fi
  local merged
  merged="$(jq -n --argjson q "$queries" --argjson r "$roots" \
    '($r | INDEX(.trace_id)) as $rt | $q | map(. + {root: ($rt[.trace_id] // null)})')"
  if [ -n "$AS_JSON" ]; then
    jq -n --arg since "$SINCE" --argjson queries "$merged" '{since: $since, queries: $queries}'
    return 0
  fi
  echo "Slowest SQL spans, last $SINCE:"
  if [ "$(jq length <<<"$merged")" -eq 0 ]; then echo "  (no query spans in the window)"; return 0; fi
  jq -r '.[] |
    "\n  \(.ms) ms  \(.name)\n    trace: \(.trace_id)"
    + (if .root then "\n    root:  \(.root.root_name)"
        + (if .root.surface != "" then "\n    ui:    surface=\(.root.surface) action=\(.root.action_resource) \(.root.action_name)" else "" end)
        + (if .root.user != "" then "\n    user:  \(.root.user)" else "" end)
       else "" end)
    + "\n    sql:   " + (if .statement == "" then "(not recorded; set OTEL_ECTO_DB_STATEMENT=true in the app)"
                         else (.statement | gsub("\\s+"; " ") | if length > 240 then .[0:240] + " ..." else . end) end)' <<<"$merged"
  echo
  echo "Next: observability trace <trace>"
}

load_config

case "${1:-}" in
  up) cmd_up ;;
  down) cmd_down ;;
  status) cmd_status ;;
  urls) cmd_urls ;;
  prepare) cmd_prepare ;;
  provision) cmd_provision ;;
  slow) shift; cmd_slow "$@" ;;
  trace) shift; cmd_trace "$@" ;;
  queries) shift; cmd_queries "$@" ;;
  restart-check) exec bash "$OBS_CONFIG_DIR/restart-check.sh" "${2:-5}" ;;
  *)
    cat <<'USAGE' >&2
usage: observability up|down|status|urls|prepare|provision|slow|trace|queries|restart-check [ROUNDS]

  up       start the stack (idempotent; first run takes about 5 minutes)
  down     stop the processes this script recorded; data is kept
  status   RSS and PSS per process against the budget (exit 2 over budget, 3 stopped)
  urls     where the UIs and endpoints are, and the sign-in
  prepare  allocate ports and write the env file without starting anything
  provision  make SigNoz's dashboards, alerts and saved views match the files again (`up` does it too)
  slow [--since 3h] [--limit N] [--by page] [--json]
           the slowest root and LiveView spans by name, or per page with --by page
           (count, p50, p95, max, worst trace); read-only
  trace TRACE_ID [--threshold 20] [--full] [--json]
           the span tree and a by-name rollup; names repeated at least --threshold
           times are flagged "likely N+1"; read-only
  queries [--since 3h] [--limit N] [--json]
           the slowest SQL spans with the root span and ui.* attributes of their trace; read-only
  restart-check [ROUNDS]
           cold restarts with traffic, each checked (default 5); leaves the stack stopped
USAGE
    exit 64
    ;;
esac
