# Trace storage for the dev-assist model: in-BEAM, external, or hybrid

*Researched 2026-09-20 by oracle (ora-2). Verified against working tree main (55e3670), mix.lock, vendored deps. Companions: otel-dev-to-prod.md, ADR 0018 (Grafana LGTM), audit-and-telemetry skill.*

## 0. The answer

**Hybrid: a bounded in-BEAM ETS ring is the source of truth for the dev loop and test-time assertions; OTLP→collector→backend (SigNoz on the homelab when reachable, LGTM in prod) is for retention, dashboards, tail sampling. The same span records feed both — via two span processors, not two pipelines.**

- **Is external SigNoz unavoidable? No.** Every dev-loop requirement is satisfiable in-BEAM; zero-infra and works-under-CI are satisfiable *only* in-BEAM.
- **Is it unadvisable? No — but it's mischaracterized as either/or.** Unadvisable only as: a dev-loop prerequisite, the inner-loop query path (ingestion race + context bloat), or the test assertion substrate. Required for retention/dashboards/tail-sampling/cross-time search.

One-sentence: **the sink is a consumer of the pipeline, not a competing pipeline.**

## 1. Requirements (key ones)

- Dev: last-N *complete* traces (eviction trace-atomic — a lying debug tool is worse than none), sub-second read-after-write, zero infra, works under test, works with `traces_exporter: :none` (repo default), context-budget output.
- **Hazard found**: the Erlang SDK batch processor defaults `scheduled_delay_ms = 5s` (deps/opentelemetry/src/otel_batch_processor.erl:86). The sink MUST hang off `otel_simple_processor` (or pinned-low delay) or the sub-second requirement dies quietly.
- CI: no services beyond Postgres; bounded memory (Ash #2921: 3.85M spans/run backstop matters most in test).
- Prod: retention/dashboards/tail sampling are collector+backend concerns; **no dev sink in prod** (env-gated supervision, not a runtime flag).

## 2. Options verdicts

- **ETS ring (GenServer writer + public ETS ordered_set keyed on :counters seq)** — recommended. VM-restart wipe is a *feature* (pre-recompile traces are lies). CircularBuffer (already in lock via tidewave, dev-only) usable as internal discipline; it's an immutable queue, not a table.
- **mnesia as span storage: wrong on every axis** (append-heavy anti-use-case, no ring semantics, dump_log thrash, 2GB dets ceiling; transactions unneeded). Right *only* potentially for the index tier (correlation↔trace, symbol↔span) — but two ETS ordered_sets do the same with no mnesia app/schema; revisit only on multi-node dev or post-mortem-of-crashed-VM workflows.
- **DETS: kill without ceremony** (no ordered_set, 2GB cap, repair stalls, persistence anti-valuable; the cross-VM sharing it implies doesn't work — use project_eval over Tidewave instead).
- **OTLP→SigNoz always: fails 5 of 6 dev requirements** (5s batch + ingestion race, 4GB/5-7 containers, CI absurdity, contradicts :none default, couples dev tool to SigNoz API churn).
- **Hybrid (simple→sink + batch→OTLP, same records)** — recommended. Verified: otel_configuration.erl:163-173 natively supports a span_processors LIST; both processors consume identical records so "same span ids" is by construction. Fan-out is configuration, exists day one.

## 3. Sibling-lane stress-test findings (all fixable)

1. "Zero latency" false under default batch config — must specify simple processor.
2. Two-VM problem unstated: project_eval into the live server is the PRIMARY dev loop; the Mix task boots its own VM (one-shots, CI, humans).
3. Bounds under-specified: need global max_spans backstop with drop-whole-oldest-trace, trace-atomic eviction as tested invariant.
4. Placement: ash_agent_tools is `only: :dev, runtime: false` — cannot own a supervision child (prod compile break). Split layers (§5.1).

## 4. Decision matrix (summary)

ETS ring wins dev/test core (with span backstop); hybrid wins overall; mnesia-spans/DETS/always-SigNoz unadvisable; mnesia-indexes overkill-for-now.

## 5. Concrete design

**Layer split:** Capture+storage+indexes = `AshEnterprise.Telemetry.TraceSink` (+ TraceSink.Exporter implementing otel_exporter behaviour) in ash_enterprise, dev/test-only conditional child (precedent: AshBpmn.Triggers.Index application.ex:120-123). Reduction (pure) = `AshAgentTools.Trace.explain(trace, opts)` in ash_agent_tools (no ETS/OTel dep; doctests on fixtures — the publishable community-missing piece). Access = `mix ash_enterprise.trace` host task + project_eval one-liner. Dependency direction: ash_enterprise → ash_agent_tools only.

**Config** (dev.exs): span_processors [{:otel_simple_processor, exporter: {TraceSink.Exporter, []}}] (runtime.exs appends batch/OTLP only when OTEL_EXPORTER_OTLP_ENDPOINT set); ring_size 50, max_spans 20_000, tables __trace_ring__ (ordered_set seq-keyed), __trace_spans__, __trace_by_correlation__/__trace_by_symbol__ (populated from ash.correlation_id/ash.symbol_id — **G1 prerequisite: without those attributes the indexes are empty**).

**explain/1 shape:** %{root, errors (innermost first), policy, queries (incl. N+1 detection), notifications, async, symbols, truncated?, backend_url} with hard budget (~8k chars) and SigNoz/Tempo deep-link when endpoint configured.

**Invariants with tests:** trace-atomic eviction; max_spans drops whole oldest traces; flood survival; partial traces never observable (root-span end = commit point). No sink→backend backfill, ever.

## 6. Verdict-change triggers

Multi-node dev → index tier to mnesia. Agent needs >ring history → widen --trace-id backend path. Sink >300 lines → reconsider shape. Post-mortem crashed-VM debugging → persistence re-hearing (answer likely still "backend has it").
