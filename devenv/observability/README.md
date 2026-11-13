# Observability for a devenv environment

SigNoz (traces, logs, metrics) and GlitchTip (errors), run natively from the Nix store: no Docker, no apt, no preinstalled binaries. `devenv up` does not start them; `observability up` does.

## Use

Import the module through `devenv.yaml` (pin `url` to a commit):

```yaml
inputs:
  ash_enterprise:
    url: github:lukegalea/ash_enterprise/<sha>
    flake: false
imports:
  - ash_enterprise/devenv/observability.nix
```

```bash
devenv up -d                          # Postgres: GlitchTip uses the project's own cluster
devenv shell -- observability up      # first run about 5 minutes, then seconds
devenv shell -- observability status  # RSS and PSS per process against the budget
devenv shell -- observability urls    # UIs, sign-in, OTLP endpoint, DSN
devenv shell -- observability down    # stops what `up` started; data is kept
devenv shell -- observability restart-check 5   # cold restarts with traffic, each checked
```

`up` is idempotent, and it reports ready only when every service it started is still running a few seconds after the last one came up. A service that exits while starting (the collector does when ClickHouse refuses its first writes) is started again, up to four times with a growing pause, and `up` fails with the end of that service's log if it never stays up. A first run downloads the stack (about 1.5 GB of store paths, realised only then, so a shell that never runs `up` pays nothing), applies the SigNoz schema migrations, and creates a sign-in shared by both tools, a SigNoz API key, the GlitchTip project, DSN and API token, and 3-day retention.

Every shell sources `.devenv/state/observability/env`, which holds `OTEL_EXPORTER_OTLP_ENDPOINT`, `SENTRY_DSN`, the UI URLs and the API credentials. `down` removes it. Restart a running app after `up` so it picks them up.

## Diagnose a slow page from its trace

Three read-only subcommands answer "why is this page slow" from the traces SigNoz already holds. They find ClickHouse and its port themselves, print plain text, and take `--json` for the same data as JSON. They read span names, durations, SQL text and the `ui.*`, `enduser.name` and `server.port` attributes only.

They need the module's generated environment (the `OBS_*` variables the module writes into the script it installs), so run them through `devenv shell -- observability ...` from a checkout that imports this module, not by calling `observability.sh` directly. A workspace whose `devenv.lock` pins an older revision of this repository does not have them yet; run `devenv update ash_enterprise` (the name of your input) first.

```bash
devenv shell -- observability slow --since 3h                          # worst root and LiveView spans, by name
devenv shell -- observability slow --by page --since 20m               # per page: timings, queries and Ash actions per trace
devenv shell -- observability slow --by page --sort queries --since 2h # the pages that run the most queries first
devenv shell -- observability trace <trace_id>                         # counts header, span tree, rollup, browser spans
devenv shell -- observability queries --since 3h                       # slowest SQL with the user action behind it
devenv shell -- observability slow --by page --since 2026-11-12T14:00 --until 2026-11-12T15:00  # one hour, compared later
```

- **`slow [--since 3h] [--limit N] [--by name|page] [--sort time|queries|spans]`** lists the slowest root spans and the slowest LiveView spans (`mount`, `handle_params`, `handle_event`, `lv.connect`) in the window, with count, p50, max and the trace id of the worst one. `--by page` groups instead by route or surface: an HTTP root and an `lv.connect` span by route, a LiveView event by its `ui.surface.id` (the LiveView module when it has none), `mount` and `handle_params` by module. A `mount` or `handle_params` takes the route of the HTTP request or `lv.connect` in its trace, so the dead render and the connected render sit with their page. Each page gets one row per kind, kept together in request order (HTTP request, connect, mount, params, events) and ranked by its worst row, so a page whose cost is all in its LiveView connect is not separated from its cheap HTTP row. Each row has count, p50, p95 and max, plus the most and the average number of queries (`%repo.query%` spans), Ash actions (spans named `domain:resource.action`) and server spans in the traces it ran in (`Q_MAX`, `Q_AVG`, `ASH_MAX`, `ASH_AVG`, `SPANS_MAX`). On a loaded host durations are flat while query counts vary tenfold, so `--sort queries` (or `--sort spans`) ranks by that instead of by time, and the worst trace in the last column is the worst on the sort key. `--by page` lists 50 pages unless `--limit` says otherwise; `--by name` lists 10 names. `--since` and `--until` each take a duration back from now (a number and `s`, `m`, `h` or `d`) or a UTC time like `2026-11-12T14:00`, so `--since 20m` limits a report to a test run and `--since 2026-11-12T14:00 --until 2026-11-12T15:00` keeps an older run comparable without reading everything since. A window too large for ClickHouse's per-query memory says so and suggests narrowing it.
- **`trace <trace_id> [--threshold 20] [--full]`** prints a header (`N spans, Q queries, A Ash actions, T ms not in any child span`), the indented span tree, and then the spans grouped by name with count, total and max time, heaviest first. `T` is the root's self time: the part of the root not covered by any direct child, and the header names the biggest such gap. Development overhead is marked: `schema_migrations` queries from `CheckRepoStatus`, and a long gap before the first query (the code reloader or a first-hit compile). A name is flagged `likely N+1` when it occurs at least `--threshold` times (default 20) in the one trace, or at least 10 times and for at least 15% of the trace's spans. The tree folds siblings that share a name into one line (`x260  total ... ms`) and expands the first; `--full` prints every span. Browser spans (`documentLoad`, `documentFetch`, `resourceFetch`, and anything from a `*-browser` service) are listed in their own section and are not part of the tree, the counts, the rollup or the flags.
- **`trace`** also reports work that went on after the root span ended: a LiveView that hands its reads to a task (`start_async`, a `Task` that keeps the trace) ends its `mount` or `lv.connect` long before the reads do, so the root's duration understates what the page cost. The header gives how long the work went on, in how many spans and queries.
- **`queries [--since 3h] [--until T] [--limit N]`** lists the slowest SQL spans with their trace id, the root span of that trace and its `ui.*` attributes, so a slow statement leads back to the user action that ran it. The statement is cut at 400 characters in ClickHouse, so statements of hundreds of kilobytes are safe. The text shows when the application records it (`OTEL_ECTO_DB_STATEMENT=enabled`, which the stack's env file sets); otherwise the line says so.
- **Filters** for `slow` and `queries`: `--service NAME`, `--port N` (the app instance that served HTTP requests on that port, found by its `service.instance.id`, so its LiveView traces count too: their `lv.connect` comes from the browser and carries no port) and `--user NAME` (`enduser.name`). `slow` hides probe routes such as `/health` and a bare `GET` root (a static asset that matched no route) unless you pass `--all`.

## Options

| Option | Default | |
|---|---|---|
| `observability.retentionDays` | 3 | Traces, metrics, logs and GlitchTip events |
| `observability.spanMetrics` | `false` | The one switch for the collector's span-metrics processor and SigNoz's matching flag |
| `observability.rootEmail` | `admin@example.com` | Sign-in for both tools; the password is generated per environment |
| `observability.organization` | `dev` | Organization name in both tools |
| `observability.appEnv` | `{}` | Extra variables for the application, written to the env file |
| `observability.provision` | `[]` | The host's own dashboards, alerts and saved views (below) |
| `observability.budgetMb` | see the file | What `status` reports against |
| `observability.memoryMaxMb` | see the file | Hard caps, applied only where systemd user scopes exist |

## What `up` collects and provisions

- **Host metrics.** The collector's `hostmetrics` receiver reports CPU, load, memory, paging, processes, network, disks and filesystems every 30 seconds, with `host.name` and `os.type`, so the machine appears under Infrastructure > Hosts.
- **Application metrics** arrive over OTLP from `AshEnterprise.Telemetry.Metrics` (`beam.*`, `phoenix.*`, `ecto.*`, `ash.*`, `oban.*`; see the telemetry package README).
- **Dashboards, alerts and saved views.** Every `up` makes SigNoz match the JSON files under `provision/`, then SigNoz's own templates, then each directory in `observability.provision`. Each directory may hold `dashboards/`, `alerts/` and `views/`, one JSON file per item in the shape SigNoz's v2 API takes (`POST /api/v2/dashboards`, `/api/v2/rules`, `/api/v2/saved_views`). Items are matched by name (a dashboard's `name`, an alert's `alert`, a view's `name`): a missing one is created, one whose file changed since it was last provisioned is replaced, and the rest are left alone, so `up` twice creates nothing twice and an edit made in the UI lasts until its file changes. A dashboard file without a `name` (SigNoz's templates use `generateName`) is named after the file.

| Provisioned | |
|---|---|
| Dashboards | BEAM VM; Phoenix & LiveView (with a User variable and a by-user table over `enduser.*` and `app.tenant.*`); Ash & Ecto; Oban; Browser. From SigNoz's [dashboards](https://github.com/SigNoz/dashboards) repository (Apache-2.0, pinned): Host Metrics, HTTP API Monitoring, DB Calls Monitoring, and APM Metrics when `spanMetrics` is on |
| Alerts | HTTP server error rate above 5%; HTTP p95 latency above 1 s; LiveView event p95 latency above 1 s; Oban jobs discarded; Oban cron worker not succeeded for 2 hours. They route through SigNoz's notification policies, so they show in SigNoz and notify nobody until a channel and a policy are set up |
| Saved views (Traces) | Slow DB queries (over 100 ms, slowest first); Errors; Browser interactions; External calls; By user. Each lists `enduser.id`, `enduser.name` and `app.tenant.name` |

A host adds its own beside them:

```nix
observability.provision = [ ./observability ];   # ./observability/dashboards/*.json, ...
```

A failed item is logged and the rest are still provisioned; `up` does not fail on it. `observability provision` does the same against a running stack, without a restart.

## Ports

Free ports are chosen by default and recorded in `.devenv/state/observability/ports`, so URLs stay stable. Set `OBSERVABILITY_PORT_<NAME>` to fix one (`CLICKHOUSE_HTTP`, `CLICKHOUSE_TCP`, `CLICKHOUSE_INTERSERVER`, `KEEPER`, `RAFT`, `OTLP_GRPC`, `OTLP_HTTP`, `COLLECTOR_HEALTH`, `SIGNOZ`, `GLITCHTIP`, `OPAMP`). Everything binds loopback. `OBSERVABILITY_SIGNOZ_PUBLIC_URL` and `OBSERVABILITY_GLITCHTIP_PUBLIC_URL` say where a proxy serves the UIs. A hosted workspace can put these in `.devenv/state/observability/config.env` (`KEY=value` lines); the process environment wins over that file.

## What is unusual, and why

- **ClickHouse runs with `memory_worker_use_cgroup=false`.** By default its memory worker takes the cgroup's usage as its own RSS. In a cgroup shared with other processes (every dev container, any terminal multiplexer's service) it believed it was tens of GiB over its cap and refused every query. With the setting off, the cap applies to the server alone.
- **Keeper Raft binds loopback through `interserver_listen_host`.** Without it, Raft listens on the wildcard address.
- **SigNoz's OpAMP listener.** It is a hard-coded `0.0.0.0:4320`, and a bind failure kills the server. OpAMP is not used here, so `up` runs a private copy of the verified binary with that string patched in place: `[::1]:00NNNN` on a host with IPv6 loopback, otherwise `0.0.0.0:NNNN`, four digits, this environment's own port. `up` stops with a clear message if the string ever moves.
- **Every ClickHouse merge is vertical.** A horizontal merge reads all columns of all source parts at once. `signoz_index_v3` has 81 columns, JSON among them, and a stack that ran for a day holds about 100 small parts of it; merging those took more than the 640 MiB cap of the time, so the merge failed and retried forever, and inserts failed beside it. Vertical merges read one column at a time and clear the same backlog in seconds. The cap, now 1 GiB, counts RSS, which includes about 200 MB of the server's own code, so a smaller `max_parts_to_merge_at_once` or `merge_max_block_size` alone did not help.
- **No system logs in ClickHouse.** The `<query_log>` and related elements are absent rather than marked `remove="1"`: in a standalone config file that attribute merges nothing and the logs are created with defaults.
- **`max_concurrent_queries` stays at 48.** Lower, and the traces exporter's parallel inserts hit the limit, retry, and duplicate every span.
- **Two checkouts of one project do not share a GlitchTip database.** GlitchTip lives in the project's Postgres cluster, which every git worktree of the project shares. The database and its login role are named `observability_glitchtip_<hash>`, where `<hash>` is the first eight hex digits of the SHA-256 of the state directory path, so each checkout provisions its own and never resets the other's password or admin user. Each checkout still runs its own ClickHouse, collector, SigNoz and GlitchTip processes (and so spends the memory budget again); to run one stack for the project, run `up` from one checkout only. A stack created before this change used the unsuffixed name `observability_glitchtip`; its first `up` afterwards starts an empty GlitchTip database (the old one is left in place and can be dropped).
- **Processes.** `down` signals only PIDs from its own records, each checked against its start time and boot id first, so a reused PID is left alone. Memory caps (systemd scopes) are used only where a user systemd exists; nothing requires one.

## Memory

`observability status` is the live figure against the budget (1,500 MB total by default: ClickHouse 800, collector 250, SigNoz 150, GlitchTip 300).

How ClickHouse is sized, and why:

- **The server cap is 1 GiB and counts RSS.** About 200 MB of RSS is the server's own code (shared, file-backed pages) and about 300 MB is what it holds after browser-suite load even though the tables are tens of MB. At the old 640 MiB cap that left no room: SigNoz's attribute-key queries (and, over a long window, the top-operations and trace-list queries) failed with `MEMORY_LIMIT_EXCEEDED`, and so did inserts.
- **A query may use 400 MB (`max_memory_usage`).** Steady RSS plus one query at its limit stays under the cap, so one heavy query fails by itself instead of failing every query and insert beside it. Aggregations and sorts spill to disk past 100 MB, and the uncompressed cache is off.
- **Smaller caches and pools.** The mark cache is 32 MiB, the background schedule pool 4 threads, merges 2 threads (vertical merges, see above). `max_thread_pool_size` must stay at 500: at 128 the server accepts connections but never answers, because its start-up and background pools together want more threads than the global pool holds.
- **Collector.** The Go heap is collected toward 128 MiB (`GOMEMLIMIT`), the `memory_limiter` refuses new data at 160 MiB, and batches are 500 spans. RSS runs 50-90 MB above the heap, so its budget is 250 MB (SigNoz's was lowered to 150 MB, which it stays under, to keep the total at 1,500 MB).

Measured with the browser suite run three times against the stack, then SigNoz-shaped trace queries (time series, top operations, trace list, attribute-key and value listings, the exceptions page) over 10 minutes, 90 minutes and 6 hours:

| After three suite runs | Before (640 MiB cap, 800 MB query limit) | After |
|---|---|---|
| ClickHouse tracked memory, peak | 451 MB | 313 MB |
| ClickHouse RSS | 443 MB | 521 MB (more data held, cap is 1 GiB) |
| Collector RSS | 132 MB | 224 MB (budget 250 MB) |
| SigNoz-shaped queries failing with `MEMORY_LIMIT_EXCEEDED` | 3 on the first pass (attribute keys over 10 minutes and 6 hours, exceptions count over 6 hours), 5 on a second pass (top operations, trace list and numeric attribute keys over 90 minutes, attribute keys over 6 hours) | 0 (one deliberate over-limit query aside) |

A query deliberately far above the 400 MB limit fails alone (`MEMORY_LIMIT_EXCEEDED`, 1.1 s) and the next ordinary query succeeds. The host these figures come from was heavily shared (load average 20-50 on 12 cores) and made the suite itself flaky, so they are indicative, not a benchmark.


Requirements: Linux on amd64 or arm64 (SigNoz publishes no other builds; the module is a no-op stub elsewhere) and a project Postgres listening on `127.0.0.1` (`services.postgres.listen_addresses`), with a superuser the shell can connect as.
