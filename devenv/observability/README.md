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
```

`up` is idempotent. A first run downloads the stack (about 1.5 GB of store paths, realised only then, so a shell that never runs `up` pays nothing), applies the SigNoz schema migrations, and creates a sign-in shared by both tools, a SigNoz API key, the GlitchTip project, DSN and API token, and 3-day retention.

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
- **No system logs in ClickHouse.** The `<query_log>` and related elements are absent rather than marked `remove="1"`: in a standalone config file that attribute merges nothing and the logs are created with defaults.
- **`max_concurrent_queries` stays at 48.** Lower, and the traces exporter's parallel inserts hit the limit, retry, and duplicate every span.
- **Processes.** `down` signals only PIDs from its own records, each checked against its start time and boot id first, so a reused PID is left alone. Memory caps (systemd scopes) are used only where a user systemd exists; nothing requires one.

## Memory

Measured on this configuration, RSS in MB: a fresh stack idle about 340 for ClickHouse, 165 for the collector, 120 for SigNoz and 240 for GlitchTip, 870 together (PSS about 790); after a five-minute load, ClickHouse 640, collector 71, SigNoz 64, GlitchTip 216, about 1 GB together and 0.75 GB private. `observability status` is the live figure; the budget defaults to 1,500 MB total.

Requirements: Linux on amd64 or arm64 (SigNoz publishes no other builds; the module is a no-op stub elsewhere) and a project Postgres listening on `127.0.0.1` (`services.postgres.listen_addresses`), with a superuser the shell can connect as.
