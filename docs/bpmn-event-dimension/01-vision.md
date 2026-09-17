# 01 — The vision

> One event backbone, one new token state, one idiom applied three ways.

## The thesis

`ash_bpmn` is a token interpreter over a compiled BPMN snapshot with exactly seven node
types and no event dimension: no message events, no timer nodes, no signals, no boundary
events, no way for anything external to reach a waiting token. `ash_decisions` is a
decision engine with no way to be *reactive*. `ash_events` is a durable, per-tenant-ordered
audit log with no subscribers. The application already bolted these together by hand —
`AshEnterprise.Process` watches the audit log and starts instances — and that bolted-together
thing is the proof of concept.

The vision is to make the connection first-class:

- **One event backbone.** The audit log, a cursor, and a dispatch identity become the
  engine's message bus. A *message* in this engine **is** an audit event. Delivery inherits
  everything the log already has: durability, per-tenant commit ordering, actor and
  correlation provenance, replay.
- **One new token state.** A token today waits only as a parked user task or a join. Add a
  general *waiting-on-subscription* state — a token row carrying what it waits for (a match
  predicate and a correlation key) — and intermediate catch events, boundary timers, and
  event sub-processes all fall out of that single mechanism instead of being five features.
- **One idiom, three ways.** `businessRuleTask` already established the correct grammar for
  binding a diagram to the host: **a reference verified at publish time + FEEL input
  expressions + named signals promoted onto routing**. Apply the same grammar to service
  tasks (`ash:call`, see `04-action-exposure.md`) and to events (`ash:subscribe`, see
  `03-event-backbone.md`).

## The three findings it rests on

### 1. The engine is a 7-node core, and it under-reports its own gaps

The executable subset is `startEvent, endEvent, userTask, serviceTask, businessRuleTask,
exclusiveGateway, parallelGateway` (`deps/ash_bpmn/lib/ash_bpmn/compiler/xml.ex:13`). That
core is sound — the token claim gate, dead-branch join reconciliation, and the
conditions-as-source-text discipline are all right. But the event dimension is not merely
absent; parts of it are **silently ignored**: a `timerEventDefinition` nested inside a
start event compiles and executes as a plain none-start (`compiler/graph.ex:328-330`), an
error end event completes the instance successfully (`graph.ex:275-321`), and the refusal
walk only checks `bpmn2:`-prefixed children of `<process>` so a `bpmn:`-prefixed
`subProcess` slips through unheard (`graph.ex:102` vs the normalizer at `xml.ex:253-256`).
A diagram can say something the engine does not do, without an error. That is the one class
of defect this repository's own conventions treat as unacceptable, and closing it is
Phase 1 regardless of anything else.

### 2. The backbone already exists, app-level, and works

`AshEnterprise.Process` is a complete audit-log-to-instance pipeline: versioned `Trigger`
rows (resource + action match → FEEL guard → DMN routing decision or static process key),
a per-tenant cursor'd sweep worker, exactly-once dispatch via an identity on
`(trigger_id, event_id)`, a post-commit nudge notifier plus a minute cron as the
completeness driver, and an ETS interest index so the 99% of writes nobody listens to cost
nothing. [`docs/plans/event-triggered-processes.md`](../plans/event-triggered-processes.md)
documents it, including the measured ordering guarantee it rests on: within one tenant,
AshEvents' per-tenant `pg_advisory_xact_lock` makes audit `sequence` order equal commit
order. The library absorption is therefore not a design from scratch; it is a promotion of
a running prototype, which is the cheapest kind of design there is.

### 3. Nothing else in the ecosystem can do this job

Every alternative substrate was checked and ruled out:

| Substrate | Why not |
|---|---|
| Ash notifiers | Fire post-commit, in-process, at-most-once. Correct as a *nudge*; wrong as a delivery mechanism. |
| `Ash.Notifier.PubSub` | In-memory, at-most-once, unordered. UI-only. |
| `ash_oban` triggers | Cron polling of *state* with an expr filter — cannot distinguish "created" from "fourth update where the filter now matches". No event semantics. |
| `ash_paper_trail` versions | Same-tx audit writes with no push channel; would be a second log. |
| `pg_notify` | At-most-once, single listener, no ordering. |

The log is the only durable, ordered, replayable feed in the system, and it already
carries actor, tenant, and correlation ids on every row. Everything engine-relevant rides
the log. This is a rule, not a preference: **Phoenix.PubSub is for UI and never a delivery
path for process semantics** (decision 3 makes it explicit for signals).

## The target architecture

```
                          ┌─────────────────────────────────────────────────┐
                          │                 Ash resources                   │
                          │   (audited actions; the only writers of fact)   │
                          └───────────────┬─────────────────────────────────┘
                                          │ same transaction
                                          ▼
                          ┌─────────────────────────────────────────────────┐
                          │        EventSource (behaviour) — the log        │
                          │  durable · per-tenant commit order · replayable │
                          └───────────────┬─────────────────────────────────┘
                                          │ cursor'd sweep (driver)
                                          │ nudge notifier (latency only)
                                          ▼
                          ┌─────────────────────────────────────────────────┐
                          │           ash_bpmn trigger engine               │
                          │  match → FEEL guard → DMN route → instantiate   │
                          │  correlation key → waiting-token delivery       │
                          └───────┬───────────────────────┬─────────────────┘
                                  │ start / advance       │ error codes
                                  ▼                       ▼
                    ┌──────────────────────────┐  ┌──────────────────────┐
                    │   token interpreter      │  │  error end / boundary │
                    │  none-start · catch ·    │  │  (route-only)         │
                    │  timer · signal · cond.  │  └──────────────────────┘
                    └──────────┬───────────────┘
                               │ ash:call (exposed actions) · decisions · human tasks
                               ▼
                          ┌─────────────────────────────────────────────────┐
                          │      Ash actions — decide · act · authorize     │
                          └─────────────────────────────────────────────────┘
```

Two cycles close: an audited write starts or advances a process; a process step calls an
audited action, whose write is itself an event. The first cycle is the feature. The second
is a hazard the existing plan already solved at app level — triggers may not match process
or decision resources, plus a bounded depth marker — and the library inherits both.

## The architectural line, restated because everything depends on it

> The process graph orchestrates. It never decides, never validates, and never authorizes.

The event dimension is the biggest temptation to cross that line yet, because event
*conditions* look like decisions. They are not. The discipline holds:

- An **event** delivers a fact: this action happened, on this record, with these changes.
- A **guard** (FEEL) filters facts. It is an expression, in-process, no I/O.
- A **decision** (DMN) answers a question — including *which process should this event
  start*. Routing decisions are the DMN-idiomatic place for selection logic.
- An **action** does the thing, with all of Ash's validations and policies attached.
- The **graph** routes between them, and reads only promoted signals.

Concretely: error boundaries route on typed errors, they do not retry business logic
(decision 5); conditional catches re-evaluate a FEEL predicate over the subject, they do
not query; a business rule task asks, a gateway reads `routing.<name>` — the composition
rules 10 and 11 of the usage rules are unchanged.

## What we refuse to build

Recorded here so nobody re-proposes it, in the convention of the existing plans:

1. **Camunda 7-style correlation** — query-over-variables at publish time. Zeebe's
   subscription model (a correlation-key *expression*, evaluated once, frozen into the
   waiting subscription) is the prior art adopted; C7's is the mistake skipped.
2. **Data objects, data stores, data associations.** FEEL over the live subject *is* the
   data model. Tokens carry routing, not business data; events carry snapshots, not live
   reads. A diagram-level data layer would create a second copy of the domain.
3. **Windowing or sequencing in FEEL** ("A then B within 5m"). FEEL is stateless per
   evaluation and stays that way. If a CEP need ever appears it is a separate layer, and
   the honest bet is that it never does.
4. **Graph-level compensation.** Within a single node, the action — or the Reactor it
   wraps — owns its own compensation (`what-it-refuses.md` already says so). The graph
   gains an error boundary, not an undo propagator.
5. **Reflective action discovery.** Diagrams may only call actions the domain explicitly
   exposed (decision 2). Reflection would make every code interface in the application a
   diagram-callable surface by default.
6. **A global cursor**, **rebuilt requester actor contexts in the dispatcher**, **guards
   written as live queries** — all refused by the existing plan (§2, §6, §9) and inherited
   verbatim by the library version.
