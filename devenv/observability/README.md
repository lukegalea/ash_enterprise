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

## Options

| Option | Default | |
|---|---|---|
| `observability.retentionDays` | 3 | Traces, metrics, logs and GlitchTip events |
| `observability.spanMetrics` | `false` | The one switch for the collector's span-metrics processor and SigNoz's matching flag |
| `observability.rootEmail` | `admin@example.com` | Sign-in for both tools; the password is generated per environment |
| `observability.organization` | `dev` | Organization name in both tools |
| `observability.appEnv` | `{}` | Extra variables for the application, written to the env file |
| `observability.budgetMb` | see the file | What `status` reports against |
| `observability.memoryMaxMb` | see the file | Hard caps, applied only where systemd user scopes exist |

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
