# ash_enterprise_telemetry

Runtime observability for Ash and Phoenix applications: one trace from a browser click through LiveView, Ash, SQL and
background jobs, errors joined to those traces, and metrics for background work. Everything is namespaced
`AshEnterprise.Telemetry.*` and needs nothing from the host beyond a few options.

## Install

As a sparse git dependency:

```elixir
{:ash_enterprise_telemetry, github: "lukegalea/ash_enterprise", sparse: "telemetry", ref: "..."}
```

## Set up

```elixir
# config/runtime.exs
config :opentelemetry,
  processors:
    AshEnterprise.Telemetry.processors(
      trace_sink: config_env() == :dev,
      otlp_endpoint: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")
    )

# config/config.exs
config :ash, :tracer, [AshEnterprise.Telemetry.AshTracer]

# Application.start/2
AshEnterprise.Telemetry.setup(otp_app: :my_app, db_statement: :enabled, otlp_logs: true, sentry: true)

# Oban
config :my_app, Oban, engine: AshEnterprise.Telemetry.ObanEngine
```

Generate the processor list; do not write it by hand. Never set the global `span_processor` or `traces_exporter` keys:
exporters are per processor. The `AshEnterprise.Telemetry` moduledoc explains the three silent failures this avoids.

Logs and metrics read their endpoint from the `:opentelemetry_experimental` application, not `:opentelemetry_exporter`, and
take their resource from the same detector as traces. `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_SERVICE_NAME` cover all three.

Exported log records carry no crash data: the OTLP log handler (and the Sentry handler) filter each record, rebuilding a
crash or error report without its arguments, last message, state or exit-reason data, with stack frames by arity, and
keeping scalar metadata only. The console handler is untouched. With Sentry's structured logs on (`config :sentry, logs:`),
also set `before_send_log: {AshEnterprise.Telemetry.SentryWiring, :before_send_log}`.

Metrics need a reader, which `setup/1` does not create:

```elixir
config :opentelemetry_experimental,
  readers: [
    %{
      module: :otel_metric_reader,
      config: %{exporter: {:otel_exporter_metrics_otlp, %{protocol: :http_protobuf}}, export_interval_ms: 15_000}
    }
  ]
```

`AshEnterprise.Telemetry.setup/1` documents every option.

To sample below 100%, go through `AshEnterprise.Telemetry.sampler/1`, or a browser that sends a valid traceparent is traced
at 100% whatever the root sampler says:

```elixir
config :opentelemetry, sampler: AshEnterprise.Telemetry.sampler({:trace_id_ratio_based, 0.1})
```

`setup/1` treats HTTP callers as untrusted by default (`public_endpoint: true`): a client's `traceparent` becomes a link and
its `baggage` is ignored. A service reached only by internal callers sets `public_endpoint: false` to continue their traces,
or passes `{module, function, args}` to decide per request.

## What needs wiring beyond `setup/1`

| Piece | Where | Module |
|---|---|---|
| Browser span ingest | Endpoint, before `Plug.Parsers` | `OtlpIngest` |
| Error reporting | `config :sentry`, Endpoint, `live_session` | `SentryWiring` |
| Browser error reports | Endpoint, before `Plug.Parsers` | `SentryTunnel` |
| Background metrics | `config :ash_enterprise_telemetry, :background_probe` | `BackgroundProbe` |
| Work in a `Task` | around the spawn | `TaskContext` |
| Trace on a Postgres session | `Repo.on_transaction_begin/1` | `Postgres` |
| Trace on outbound HTTP | around `Req.new/1` | `AshEnterprise.Telemetry.Req` |
| Naming the action on a span | `setup(event_attributes: ...)`; `declared:` for actions not in the UI module | `A2uiEventAttributes` |

Attribute names are a documented contract: `AshEnterprise.Telemetry.Attributes`.

## Browser

`priv/js` holds the tracer (`otel_browser.js`), the socket wrapper (`socket_tracing.js`) and error reporting
(`sentry_browser.js`). `priv/js/package.json` lists the exact package versions to install in the host's `assets/package.json`.
The OpenTelemetry JS packages must be pinned as a set.

Browser tracing is off until the root layout renders `<meta name="otel-browser" content="on">`. Adopting the browser's trace
context on the server is a separate switch, `browser_context: true`; its trust model is in the `BrowserContext` moduledoc.

## Tests

```sh
mix test
node --test test/js/*.mjs
```

The suite needs a Postgres reachable through the standard `PG*` variables and creates its own database.
