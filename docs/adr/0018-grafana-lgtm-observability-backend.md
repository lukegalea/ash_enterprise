# ADR 0018 — Grafana LGTM as the observability backend

- **Status:** proposed
- **Date:** 2026-08-18

## Context

The instrumentation side of observability is decided and partly built. `mix.exs` carries six direct
`opentelemetry_*` dependencies (`opentelemetry`, `opentelemetry_api`, `opentelemetry_exporter`,
`opentelemetry_ash`, `opentelemetry_phoenix`, `opentelemetry_ecto`).
`config/config.exs` sets `config :ash, :tracer, [OpentelemetryAsh]`, so every Ash action, query,
changeset, validation, change and calculation becomes a span with no per-resource wiring.
`lib/ash_enterprise/platform/correlation.ex` threads a correlation id through a request and stamps it
onto every audit event. `lib/ash_enterprise_web/telemetry.ex` declares the metric set, per domain and
per action type.

What is **not** decided is where any of that lands and how anyone queries it. `traces_exporter` is
`:none`, which is the right default for a template — exporting by accident is worse than not exporting —
but a default is not a destination.

Three smaller facts, verified by reading the tree on 2026-08-18, because they change what this ADR is
allowed to claim:

- `config/runtime.exs` contains **no OTLP configuration at all**, despite the comment in
  `config/config.exs` pointing at it.
- `OpentelemetryPhoenix.setup/1` and `OpentelemetryEcto.setup/1` are **never called** anywhere in `lib/`
  or `config/`. Both packages are declared and neither is attached, so today the only spans that would
  be produced are Ash's.
- `AshEnterpriseWeb.Telemetry.metrics/0` is defined and **nothing consumes it**. The supervisor starts
  `:telemetry_poller` only; the reporter line is commented out. LiveDashboard reads it in dev.

So the honest starting position is that instrumentation is *declared*, not *wired*, and picking a
backend is the smaller half of finishing it.

The candidate backends were compared on licence rather than features, because the feature question has a
boring answer — anything that speaks OTLP will do — and the licence question does not. Verified from
`LICENSE` files on 2026-08-18:

| Component | Licence | Latest |
|---|---|---|
| Grafana | **AGPL-3.0** | v13.2.0 (2026-08-18) |
| Loki (logs) | **AGPL-3.0** | v3.7.6 (2026-08-06) |
| Tempo (traces) | **AGPL-3.0** | v3.0.3 (2026-08-13) |
| Mimir (metrics) | **AGPL-3.0** | mimir-3.1.4 (2026-07-22) |
| Prometheus | Apache-2.0 | v3.14.0 (2026-08-18) |
| OpenTelemetry Collector | Apache-2.0 | v0.159.0 (2026-08-17) |
| Grafana Alloy | **Apache-2.0** | v1.18.1 (2026-08-06) |

Grafana, Loki and Tempo relicensed from Apache-2.0 to AGPLv3 on 2021-04-20; Mimir was AGPLv3 from its
2022 launch. **Alloy is Apache-2.0**, which is the fact worth noticing: the *collection* tier is
permissive and the *storage and visualisation* tier is copyleft. That is the actual shape of the mix,
and it is not an accident — Alloy is the component you would vendor into an agent or embed in a product,
which is exactly where AGPL would bite.

What AGPLv3 means for a company self-hosting Grafana internally, stated factually and not as legal
advice: §13 adds one obligation over GPLv3 — if you **modify** the program **and** let users interact
with it remotely over a network, those users must be offered the corresponding source. Both conditions
are required. Running unmodified Grafana for your own staff triggers neither, and the FSF is explicit
that copying within one organization is not distribution. The clause bites on modify-plus-expose, and on
shipping or hosting it for third parties.

One deprecation to record because it is a live migration rather than history: **Grafana Agent reached
end-of-life 2025-11-01** (deprecated 2024-04-09, LTS ended 2025-10-31), replaced by Alloy. Promtail is
EOL alongside it. Anything written against Agent or Promtail is already the wrong starting point.

## Decision

**Traces, metrics and logs go to the Grafana LGTM stack — Loki, Grafana, Tempo, Mimir — reached through
an OpenTelemetry Collector or Grafana Alloy. Prometheus is acceptable in place of Mimir where
single-binary metrics storage is sufficient.**

**The Ash-side work is approximately zero, and inflating it would be dishonest.** The exporter is already
a dependency. Turning this on is an `OTEL_EXPORTER_OTLP_ENDPOINT` in `config/runtime.exs`, a
`traces_exporter: {:otel_exporter_otlp, …}` in place of `:none`, and a collector to point at. Nothing in
`lib/` changes. The decision being recorded is that a destination exists and is named, not that a
system was built.

The three gaps found above are the actual work, and they are follow-ups rather than parts of this
decision: call `OpentelemetryPhoenix.setup/1` and `OpentelemetryEcto.setup/1` in the application start;
add `opentelemetry_bandit` (Bandit is the endpoint adapter) and `opentelemetry_oban` (AshOban is a
dependency), neither of which is currently declared; and attach a reporter to
`AshEnterpriseWeb.Telemetry.metrics/0` so the declared metrics reach Mimir or Prometheus instead of only
LiveDashboard.

Choosing the collector over direct OTLP-to-backend is the one non-obvious part, and the reason is
[thesis 6](../manifesto/06-reversibility.md): the application exports OTLP to one endpoint and knows
nothing about what is behind it, so replacing Tempo with anything else is collector configuration rather
than an application change. That is the seam, and it costs one extra hop.

## Does it consume ActorContext?

No, and it must not. Spans and metrics are emitted by a process that has an actor in scope; putting
`ActorContext` contents into span attributes would export the actor's precomputed grant map — business
unit ids, team ids, the whole privilege set — into a system with a different access model, which is
exactly the duplication [ADR 0014](0014-superset-over-metabase.md) and
[ADR 0016](0016-unleash-for-feature-flags.md) reject in their own domains. Telemetry is the one place
where *not* consuming it is the correct answer.

The identifier that should cross the boundary is the correlation id from
`AshEnterprise.Platform.Correlation`, because it is opaque and is already the join key between the audit
log and a request. A user id is defensible as a span attribute; the resolved authorization context is
not.

Worth recording as a real limitation rather than a footnote: `Correlation` stores its id in the process
dictionary and its own moduledoc says so — work handed to a `Task` or an Oban job starts a new id unless
`with_correlation/2` is used deliberately. OTel context propagation has the same boundary and its own
answer (`opentelemetry_process_propagator`, already present transitively). These are two mechanisms
solving the same problem separately, and nothing currently reconciles them.

## Consequences

**Made easy.** A named destination for the telemetry that already exists. Vendor neutrality is preserved
— [thesis 6](../manifesto/06-reversibility.md) records the AppSignal trade explicitly, and this is the
other side of it. Alloy being Apache-2.0 means the component deployed onto every host carries no
copyleft obligation.

**Made hard.** Four services instead of one product, with retention, cardinality and object storage to
configure — which is the cost of not buying AppSignal, and it is real. AGPL on the storage and
visualisation tier is fine for internal self-hosting and is a genuine constraint if Grafana is ever
modified and exposed, or embedded in something shipped.

**What this does not close.**
[Thesis 7 entry 9](../manifesto/07-what-we-do-not-have.md#9-opentelemetry-depth) stays open, and it
would be wrong to claim otherwise. That entry is about the *bridge* — `opentelemetry_ash` being thin
relative to enterprise APM — not about the backend. Checked 2026-08-18: `opentelemetry_ash` is still
**0.1.3, published 2025-07-11**, thirteen months stale on hex. The repository is not dead (last push
2026-08-04) but the recent commits are all dependency bumps, with no feature work since 0.1.3. It tracks
Ash releases and is not being developed. Naming a backend does not change the depth of what reaches it.

For the record, the neighbouring packages as of 2026-08-18: `opentelemetry` 1.7.0 and
`opentelemetry_api` 1.5.0 (both 2025-10-17), `opentelemetry_exporter` 1.10.0, `opentelemetry_phoenix`
2.0.1 (2025-02-21), `opentelemetry_ecto` 1.2.0 (2024-02-06, the stalest — and note 1.1.2 is retired on
hex, so a resolver must not land there), `opentelemetry_bandit` 0.3.0, `opentelemetry_oban` 1.2.0
(2026-02-27).

## Reversal

The cheapest reversal in this directory, by construction.

**To switch backends:** change the collector's exporter configuration. No file in `lib/` and no line in
`mix.exs` names Tempo, Loki, Mimir or Grafana — the application knows one OTLP endpoint. That is the
whole point of routing through a collector, and it is what makes this decision worth less anxiety than
the others recorded here.

**To go to a commercial APM instead:** point the same OTLP endpoint at a vendor that accepts it, or swap
`opentelemetry_ash` for `ash_appsignal`, which
[thesis 6](../manifesto/06-reversibility.md) already records as more polished and the integration the
Ash docs endorse. The cost is lock-in, and the reason it is not the default is written down there.

**To turn observability off entirely:** it already is. `traces_exporter: :none` in `config/config.exs`
is the current state, and reverting to it is one line.
