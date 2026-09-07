# The BPMN event dimension

> **Status: Phase 1 built; Phases 2–5 specified, not built.** Written 2026-09-06 after a
> research pass over `ash_bpmn`, `ash_decisions` / `boxic_feel`, `ash_events`, the ecosystem's
> reactive primitives, the Ash notifier seam, and Camunda 7 / Camunda 8 (Zeebe) prior art.
> Decisions taken 2026-09-06; the PRD's open questions settled 2026-09-07 at Phase 1 review.
> Phase 1 verification: 295/295 library tests, 48/48 app integration tests.

This directory holds the vision for giving `ash_bpmn` the event dimension it currently
refuses to have — message and timer events, signals, conditional catches, error routing —
by building them on the one durable, ordered event substrate an Ash application already
owns: the audit log.

It extends [`docs/plans/event-triggered-processes.md`](../plans/event-triggered-processes.md)
(status: **built** — its patterns exist as the app-level `AshEnterprise.Process` domain) by
absorbing those patterns into the library and continuing where that plan deliberately
stopped: it could *start* processes from events, but the engine had no way to *wait* for
them.

## Documents

| Document | What it holds |
|---|---|
| [`01-vision.md`](01-vision.md) | The thesis, the three findings it rests on, the target architecture, and what we refuse to build |
| [`02-mappings.md`](02-mappings.md) | The BPMN ↔ Ash mapping table — every element, its Ash concept, its status today, its target, its phase |
| [`03-event-backbone.md`](03-event-backbone.md) | Subscriptions, correlation, delivery semantics, FEEL discipline, and the absorption of the Process domain into `ash_bpmn` behind an `EventSource` behaviour |
| [`04-action-exposure.md`](04-action-exposure.md) | `ash:call` — exposing Ash actions to diagrams the way `ash_ai` exposes them to agents |
| [`05-hygiene.md`](05-hygiene.md) | Engine defects found during research, unrelated to the vision but worth fixing on the way |
| [`06-roadmap.md`](06-roadmap.md) | The five phases, with the decisions below applied |
| [`research-findings.md`](research-findings.md) | The evidence base: condensed findings from the research pass, with file:line citations |
| [`prd.md`](prd.md) | **The requirements — the *what*.** Capabilities (FR-x), cross-cutting semantics, guarantees (G-x), operational and security requirements, non-goals, acceptance themes, open questions |
| [`trd.md`](trd.md) | **The technical design — the *how*.** `EventSource` behaviour, `callables` DSL, resource schemas, sweep and correlator mechanics, the waiting state, compiler/snapshot changes, replacement of the app prototype, testing, risks |

## Decisions taken, 2026-09-06

1. **The Process domain's patterns are absorbed into `ash_bpmn`** — as an optional extension
   behind an `EventSource` behaviour — not kept as an app-level sidecar and not split into a
   sibling package. The app code is the prototype; the library takes the pattern, the app
   keeps its audit-log-specific coupling.
2. **Action exposure follows `ash_ai`'s style**: actions are invokable from diagrams only
   when the domain explicitly marks them, exactly as `ash_ai` marks the actions agents may
   call. Explicit declaration, verified at publish time; no reflective discovery.
3. **Signals are durable-log-only.** A signal is a row in the event log; it is consumed by
   the sweep like any other event. Phoenix.PubSub remains for UI and is never a delivery
   path for process semantics.
4. **The single-instance-per-correlation-key guard is deferred** until a use case demands
   it. The aggregator pattern (every matching event correlates into the waiting or new
   instance) is the only instantiation shape in v1. The deferred design is sketched, not
   scheduled.
5. **Error boundaries are route-only.** A boundary routes on a typed error; it never
   retries. Retries remain Oban's job at the job level, bounded by `max_attempts`, exactly
   as today. There is no retry/backoff contract in the graph.

## Note, 2026-09-07

No production system runs the app-level trigger pipeline — `AshEnterprise.Process` has
never existed outside this repository's development history. The absorption therefore
needs no cutover: `trd.md` §10 specifies direct replacement (the library lands, the
prototype modules are deleted in the same change, nothing migrates), and the
dual-run/shadow-dispatch machinery an earlier revision carried has been removed. This
note records the change; a matching correction is appended to
[`plans/event-triggered-processes.md`](../plans/event-triggered-processes.md).

## What comes next

Implementation of Phase 1 (honest compilation + designer basics), which stands alone and
blocks nothing; the PRD's four open questions are settled at TRD review before Phase 2
begins. Read in this order: `01-vision.md` → `prd.md` → `trd.md`, with
`research-findings.md` as the citation appendix.
