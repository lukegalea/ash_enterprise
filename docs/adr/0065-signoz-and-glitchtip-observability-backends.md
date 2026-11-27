# ADR 0065 — SigNoz for traces, logs and metrics; GlitchTip for error triage

- **Status:** accepted (2026-11-12; proposed 2026-11-09); amended 2026-11-26 (with ADR 0086): a span links a journey step to its audit rows, and the audit row is the proof
- **Date:** 2026-11-09
- **Supersedes:** ADR 0018 (Grafana LGTM as the observability backend)
- **Related:** ADR 0056 (the same shape: a public package the host instantiates)

## Context

ADR 0018 proposed Grafana LGTM and was never built. The requirement that decides between backends is narrower than
"observability": from a running non-production environment, a person clicks around, finds a slow database query, and sees
which user action prompted it, in one tool, on a machine that is also running the application and its database.

That rules on three properties:

- **One query surface over traces, logs and metrics.** LGTM is four services (Loki, Grafana, Tempo, Mimir) with three
  query languages. SigNoz is a collector, one server and ClickHouse, with one query API.
- **A memory footprint that fits beside the application.** Measured below.
- **An error triage queue.** Trace backends list exceptions, but triage means grouping, assignment and resolution.
  SigNoz's Exceptions page is good for "the exception on this trace" and is not that queue.

## Decision

1. **SigNoz receives OTLP traces, logs and metrics.** Self-hosted, community edition, ClickHouse with embedded Keeper.
2. **GlitchTip receives errors**, through the Sentry SDK and its envelope protocol. It is smaller than self-hosted Sentry by
   an order of magnitude and speaks the same wire format, so moving to Sentry later is a DSN change.
3. **Each answers one question; alert on one of them.** SigNoz's Exceptions page answers "what failed on this trace".
   GlitchTip is the triage queue. Both see every error, and alerting on both pages someone twice.
4. **Sentry's own OpenTelemetry span processor, propagator and sampler stay off.** Traces belong to the OTLP pipeline.
   Turning them on sends every span a second time and replaces the sampling decision. Errors are joined to traces by
   `trace_id`, `span_id` and `correlation_id` tags instead, set in `before_send`, and found with a `trace_id:<hex>` search.
5. **Instrumentation is the `ash_enterprise_telemetry` package** (`telemetry/`), usable through a sparse git dependency
   with no dependency on this application, the shape ADR 0056 set for the agent runtime. Its `AshEnterprise.Telemetry.processors/1` generates the span
   processor list, because the SDK has three configuration traps that fail silently (see that module).

## Non-production sizing

Measured on one host, the final configuration, five minutes at 5 iterations per second (a two-span trace, a log and a metric), plus a Sentry event every 5 seconds. ClickHouse LTS 26.3, SigNoz 0.149, collector 0.144,
GlitchTip 6.2, with no span-metrics processor. Megabytes:

| Process | Steady RSS | Peak RSS | Steady private (anon) |
|---|---|---|---|
| ClickHouse with Keeper | 640 | 691 | 410 |
| Collector | 71 | 191 | 54 |
| SigNoz | 64 | 111 | 31 |
| GlitchTip, web and worker in one | 216 | 243 | 180 |
| Postgres for GlitchTip | 227 | 227 | 49 |
| **Total** | **1,218** | **1,452** | **724** |

Budget 1.5 GB against the 4 GB SigNoz documents. About 680 MB of the RSS sum is file-backed binary text, so a budget should
be set on private memory or PSS, not raw RSS. These numbers are for the light load above; heavier ingest was not tested.

Three settings are load-bearing for that figure: ClickHouse needs its own cgroup (it reads the cgroup's usage as its own RSS
and refuses queries), `max_concurrent_queries` must stay well above 8 (below it the exporter retries and duplicates every
span row), and `max_server_memory_usage` is 640 MiB. Retention is 72 hours for traces and metrics; logs go down to whole days.

## Trust stance

Non-production telemetry is treated as sensitive but not secret, and browser telemetry as untrusted input.

- SQL text on database spans is parameterized and is a per-environment switch, off by default. Bound values are not sent.
- The browser may contribute a parent trace context only when a deployment turns that on, and it is strictly validated. A
  client's sampled flag is replaced so it cannot suppress sampling, and `AshEnterprise.Telemetry.sampler/1` sends those
  spans to the root sampler so it cannot force it either. Correlation ids are server-minted and never accepted from the
  client.
- HTTP callers are untrusted by default: an incoming `traceparent` becomes a link rather than a parent and `baggage` is
  ignored. Query strings reach spans as parameter names only, and recorded stack frames carry arity, never arguments.
- Browser spans arrive through a same-origin endpoint that checks method, content type and `Origin`, caps size and rate, and
  strips `ash.*`, `audit.*` and correlation attributes, because those are server-asserted facts. A forged browser span can
  add noise to a trace; it cannot claim to be server evidence or change an audit record. Spans are diagnostics, and the audit
  log remains the record.
- Error events have LiveView parameters and request bodies reduced to their keys, query strings, stack-frame arguments, a
  crashed process's state and user PII removed before they leave; if scrubbing fails the event is dropped.
- Exported log records follow the same rule. A crash or error report (GenServer, `gen_statem`, `proc_lib`, supervisor,
  Task, Bandit, LiveView) is rebuilt from its sanitized parts, without arguments, last message, state or exit-reason data,
  with frames by arity, and log metadata keeps scalars only. The filter that does this applies to the exporting handlers
  (OTLP, and Sentry's), not the console; if it fails the record is dropped.
- A client-chosen name reaches a span attribute only when the server declared it: an A2UI row action is named on the span
  only if the surface declares it, otherwise the span carries the envelope's verb.
- Browser attribute values are limited to scalars, so a reserved key cannot arrive nested inside a list or map value.
- The stack is bound to loopback or a private network. Two listeners ignore that today (SigNoz's OpAMP port and Keeper's raft
  port) and must be firewalled.

## Consequences

- The Grafana configuration ADR 0018 proposed is not built. `docs/adr/0018` is marked superseded.
- Logs and metrics use `opentelemetry_experimental`, which is pre-1.0. A breaking change there affects those two signals and
  not traces.
- ClickHouse is one more stateful service to run in a development environment, offset by not running four.
- Production backend sizing and retention are not decided here.

## Amendment — 2026-11-26 (with ADR 0086): a span links a step to its audit rows; the audit row is the proof

This amendment takes effect with [ADR 0086](0086-a-journey-is-one-declaration-with-proven-projections.md). The text
above is unchanged, and the trust stance holds in full: browser telemetry is untrusted input, and the audit log remains
the record. Where this amendment and the text above appear to conflict, the text above governs what a span is, and this
amendment governs what a test or a journey may conclude from one.

**Why it is needed.** Browser tests read spans to learn what server work a user step caused, and journey runs
(ADR 0086) record that in their run manifests. Spans gained a consumer that draws conclusions, so this record has to
say which conclusions a span supports. As built on 2026-11-26:

- the generated row-action test in `ash_browser_tests` passes the `ash.correlation_id` of the step's `handle_event`
  span to the host's `assert_audit/2`, and this repository's e2e wiring (`test/support/e2e/surfaces.ex`) asserts an
  audit row with that correlation id, for the record and the action the test ran;
- a journey step that declares `expect audit: true` asserts one correlation id across its server spans, then, for
  each row action of the step, the host (`test/support/e2e/journey_host.ex`, `assert_audit/3`) asserts the audit row
  with that correlation id written by that action of its resource, about the record it acted on, no earlier than the
  step began. A LiveView keeps one correlation id for its whole life, so the action, the record and the time are what
  keep an earlier step's rows from proving a later one.

1. **A span is a link and never evidence.** A step is proved by audit rows: rows in `audit_events` that carry the
   step's correlation id, written by the action the step names, about the record it names. Those rows are
   tamper-evident (ADR 0020). A span chain that matches with no such row does not prove the step.
2. **The correlation id comes from a server span.** A step reads it from the server span its browser span caused
   (the `handle_event` or action span), never from a browser span. This follows from the stance above: correlation
   ids are server-minted, and browser spans have `ash.*`, `audit.*` and correlation attributes stripped at ingest. The
   browser span only anchors the step: it is the root under which the step's server spans are found.
3. **Spans can fail a step and never pass one.** A missing, forged, extra or sampled-out span can make a step fail or
   leave it unlinked. It cannot make a step pass. A step with no audit row for its correlation id fails, whatever the
   spans show.
4. **One step, one correlation.** A step asserts a single `ash.correlation_id` across its server tree before it reads
   audit rows, so rows written by unrelated work are never claimed for it.
5. **The correlation id is kept; span ids are for diagnosis.** A run manifest records each step's correlation id and
   span ids. Span ids let a reader open the trace while the backend still holds it (72 hours above). The correlation
   id and the audit rows it names are what a reader uses later, so no evidence depends on trace retention.
6. **Selecting spans is not authenticating them.** Tests select spans by a per-test key carried from the test
   sandbox. The key finds spans in a shared pipeline; it says nothing about who produced them, and rules 1 to 3 do not
   rest on it.
7. **Sampling is not changed for tests or journeys.** A browser still cannot force or suppress sampling. In a run
   against a deployment we operate, a step whose spans were not sampled is unlinked and is not evidence. Whether
   journey runs there need every step sampled, and how the server would decide that without trusting the client, is
   not decided here.

**Unchanged:** the backends, the ingest endpoint and its checks, attribute stripping, scrubbing, the sampler, and
the rule that spans are diagnostics.

To reverse this amendment, delete it, and remove the correlation-id and span-id fields from the journey run manifest
(ADR 0086). Steps would then be proved by their record expectations alone, and no browser test would read audit rows
through a span.
