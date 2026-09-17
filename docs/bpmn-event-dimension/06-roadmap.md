# 06 — Roadmap

Five phases, each with an exit criterion. The decisions of 2026-09-06 (README) are applied
where they bite and numbered `D1`–`D5`.

## Phase 1 — Honesty and designer basics

> **Status: built, 2026-09-07.** Compiler refuses every unimplemented construct at any
> nesting (14-fixture corpus), prefixes normalize before classification, warnings
> mechanism + FEEL engine stamp in the snapshot, `:timer_cancelled` emitted, `my_tasks`
> single-query, join semantics corrected in DESIGN.md; designer authors conditions,
> default flows, and decision bindings with FEEL validation, and surfaces publish
> errors with jump-to-element highlighting. Verified 295/295 library, 48/48 app
> integration.

**Scope.** Close the silent-ignore class: the compiler refuses unrecognized child elements
on supported nodes and normalizes prefixes before classifying (hygiene #1, #2). Gateway
condition editor in the designer (validate via `Boxic.FEEL.parse`, surface
`:condition_null` diagnostics). `businessRuleTask` forms in the properties panel — the
moddle vocabulary already round-trips `decision`/`inputs`/`promote`; only the form is
missing. Hygiene #7 (`:timer_cancelled`), #8 (`my_tasks` N+1), #9 (document the join
rule).

**Exit criterion.** No legal-in-bpmn.io diagram compiles to semantics it does not have:
every unsupported element or attribute, at any nesting level, is a named publish error. A
designer can author a complete process — conditions, decisions, tasks — without touching
XML.

## Phase 2 — The backbone, absorbed

> **Status: built, 2026-09-07.** Library PRs #6–#9: the `EventSource` behaviour and
> `callables` seam; Subscription/Cursor/Dispatch with the full publish-validation
> chain; the sweep/correlator/nudge/index engine; `ash:call` end to end with its
> designer panel. App PR #5 (merged): the app runs the engine through an
> `AshEvents` adapter and its Process prototype is deleted in the same migration.
> Verified 406/406 library tests, 274/274 app tests, and a dev smoke — audited
> write → sweep → dispatch row → instance → human tasks. The exit criterion's
> dispatch ledger answers *why did this instance start* in production shape.

**Scope.** D1: the `AshEnterprise.Process` patterns move into `ash_bpmn` behind
`AshBpmn.EventSource` (reference adapter: `ash_events`, with its ordering guarantee and
its two caveats declared). Message start events: definition-level subscriptions with
resource/action match, FEEL guard, FEEL correlation expression, DMN routing or static
process key — versioned, published, `enabled` as the operational switch. Dispatch ledger
with `(subscription_id, event_id)` identity; sweep driver + nudge notifier + cron net;
ETS interest index. Cycle invariant: subscriptions may not match engine or decision
resources; depth bound in dispatch metadata. D2: `AshBpmn.Domain` with the `callables`
block, `ash:call` on service tasks, publish-time verification, callable dropdown in the
designer (`04-action-exposure.md`). The app's `Process` domain becomes the reference
consumer; `Binding`/baseline resolution stays app-level, feeding the engine a resolved
definition.

**Exit criterion.** The app runs on the library's trigger engine; its `Process` domain is
deleted except the baseline/binding layer. A published diagram starts on an audited
write, end to end, with the dispatch row answering *"why did this instance start?"*.

## Phase 3 — Waiting

**Scope.** The general waiting-token state: a token parks with
`(node_id, correlation_key, subscription)`. Message intermediate catch events, delivered
by the sweep through the existing claim gate; optional per-subscription `lookback`
(early-event buffer, durable by being a log re-scan). Timer intermediate catch: the
generalized `TimerJob`; user-task `expire` promoted to a first-class interrupting timer
boundary — and expiry routing fixed to evaluate conditions like any other transition
(hygiene #3, #4, #5). Error end events (typed failure codes) and route-only error
boundaries (D5): a boundary routes on an error class to a recovery path; retries remain
Oban's job, bounded by `max_attempts`, unchanged. Terminate end event: kill all sibling
tokens. `ash:load` declarations on gateways/tasks, loaded strictly, FEEL sees `nil` on
unloaded paths.

**Exit criterion.** A process can *wait* — for an event, a duration, or an error — and
be woken or routed correctly, with redelivery-safe delivery proven by tests (claim-race,
late-event-after-cancel, expiry-honors-conditions).

## Phase 4 — Broadcast and scoping

**Scope.** Signals, durable-log-only (D3): a signal throw writes an event row of kind
`signal` through an audited action; the sweep delivers to every matching subscription —
broadcast, not consumed. Signal start and catch events. Conditional catches: subject-update
subscriptions with a FEEL guard over the subject, dependency paths derived from the AST
as an index optimization. Escalation: generalized from `AssignmentResolver.escalate/2` to
escalate-to-process via signals; the swallowed-exception rescue fixed (hygiene #6).
Non-interrupting timer boundaries. Event sub-processes: instance-scoped subscription sets,
interrupting or not, on the same waiting mechanism.

**Exit criterion.** The full event taxonomy the vision commits to is live: message,
timer, signal, conditional, escalation — start, catch, boundary, sub-process — with
signal delivery provably durable and ordered (replay a tenant's log; every signal has
ledger rows saying who caught it).

## Phase 5 — Structure, if earned

**Scope.** Call activities: start a child instance, wait for its completion event —
process-as-action. Multi-instance: FEEL list expression fans out tokens, sequential or
parallel, joining on completion. Send/receive task sugar. Nothing in this phase is built
without a naming a use case; each item names its use case in the PRD before it is
scheduled.

**Exit criterion.** None pre-declared; per-item, with the use case that earned it.

## What no phase contains

Refused permanently (vision `01`, "What we refuse to build"): Camunda 7-style
correlation; data objects/stores/associations; FEEL windowing or sequencing; graph-level
compensation; reflective action discovery; a global cursor; rebuilt requester actor
contexts; guards as live queries. Deferred with a sketch (D4): the
single-instance-per-correlation-key guard — the aggregator pattern is v1's only
instantiation behaviour, documented as behaviour.
