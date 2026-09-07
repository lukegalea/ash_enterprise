# 02 — BPMN ↔ Ash mappings

The direct answer to *which process elements obviously tie to Ash concepts, and which ties
are missing*. Status codes: **done** (exists today), **gap** (missing mapping, part of this
vision), **refused** (deliberately not built — see `01-vision.md`).

Phases refer to `06-roadmap.md`.

## The table

| BPMN element | Ash concept | Status | Target | Phase |
|---|---|---|---|---|
| none start event | explicit `start_instance!` call | **done** | unchanged | — |
| message start event | Audit event (resource + action) → new instance | **gap** (app-level only, `AshEnterprise.Process.Trigger`) | first-class `ash:subscribe`; DMN routing for process selection | 2 |
| timer start event | Oban cron per published definition | **silently ignored** | refuse loudly, then implement | 1, 4 |
| signal start event | Durable signal event → new instance(s) | **nothing** | log-row signals, broadcast semantics | 4 |
| conditional start event | deferred with the single-instance guard | **nothing** | not built (decision 4 applies) | — |
| none end event | instance completes; `ash:taskConfig outcome` | **done** | unchanged | — |
| message end event | emits a fact others may subscribe to | **gap** | an audited action *is* this; end event may name it for the designer | 4 |
| error end event | instance `:failed` with a typed error code | **silently ignored** — error ends complete successfully (`graph.ex:275-321`) | typed failure + code, surfaces in `instance_report` | 3 |
| terminate end event | kill all sibling tokens (`cancel_instance!` semantics) | **gap** | new node effect | 3 |
| message intermediate catch | token waits for audit event matching correlation key | **refused as node; no waiting machinery exists** | waiting-token state + subscription row | 3 |
| timer intermediate catch | Oban job at `now + duration`, cancellable | **refused** | generalized `TimerJob` (task timers already exist as config) | 3 |
| signal intermediate catch | token waits for signal event of a kind | **refused** | subscription on signal kind | 4 |
| signal intermediate throw | write a signal event to the log | **refused** | durable-log-only (decision 3) | 4 |
| conditional intermediate catch | FEEL predicate over subject, re-evaluated on subject events | **refused** | subject-update subscription + guard; dependencies from FEEL AST | 4 |
| boundary: timer (interrupting) | user task `expire` timer | **exists as task config, not diagram vocabulary** (`graph.ex:471-551`) | promoted to first-class boundary on user tasks first | 3 |
| boundary: timer (non-interrupting) | escalation spawn | **gap** | after interrupting lands | 4 |
| boundary: error | route on typed error from `ash:call` / invoker failures | **gap** | route-only (decision 5) | 3 |
| boundary: message / signal | scope-local subscription | **gap** | same waiting-token mechanism | 4 |
| escalation events | generalized `AssignmentResolver.escalate/2` seam | **task-level only; errors swallowed** (`timer_worker.ex:64-92`) | escalate-to-process via signal; swallowed-error bug fixed | 4 |
| compensation | action-owned / Reactor undo | **refused** — stays refused | none | — |
| service task | code interface | **opaque string** through `ActionInvoker` (`graph.ex:215-227`) | `ash:call` to a domain-exposed action (`04-action-exposure.md`) | 2 |
| business rule task | `ash_decisions` definition | **done — the template** (`graph.ex:332-469`) | add designer forms (today XML-only) | 1 |
| user task | `HumanTask` + `TaskCandidate` rows | **done** | unchanged | — |
| exclusive gateway | FEEL conditions + default flow | **done** (`interpreter.ex:358-434`) | add condition editor in designer | 1 |
| parallel gateway | fork/join + dead-branch reconciliation | **done** (`advance_worker.ex:147-206`) | formalize the reconciliation rule in docs | — |
| inclusive gateway | — | **refused** | stays refused until dead-path semantics are decided deliberately | — |
| event-based gateway | race between catch events | **refused** | arrives with Phase 3/4 catch events if a use case earns it | — |
| event sub-process | instance-scoped subscription set | **refused** | the clean alternative to boundary spaghetti | 4 |
| embedded sub-process | — | **refused** | stays refused (structural sugar, real cost) | — |
| call activity | child instance + wait for completion | **refused** | process-as-action | 5 |
| multi-instance | FEEL list expression over subject | **silently ignored today** | for-each (the line-item approval story) | 5 |
| send / receive tasks | sugar over throw / catch | **refused** | only if designers ask | — |
| data objects / stores | — | **refused** | FEEL-over-subject *is* the data model | — |
| subject (implicit) | the resource record the instance is about | **done** (read via FEEL, `subject.*`) | optional per-node `ash:load` declarations | 3 |
| correlation (implicit) | subject identity / correlation key | **write-only today** (`ash_bpmn.ex:85-89`) | FEEL key expression on start/catch subscriptions | 2 |
| versioning | definition pinned for instance life | **done** | triggers and subscriptions version the same way | 2 |

## The idiom, three ways

The mappings above that touch the host all use one grammar, established by
`businessRuleTask` and now applied to actions and events:

| | businessRuleTask (done) | service task (target) | event subscription (target) |
|---|---|---|---|
| **Reference** | `ash:decision ref= binding= [version=]`, verified at publish via `DecisionResolver.exists?/1` | `ash:call ref=`, verified at publish against the domain's exposed callables | `resource=` + `action=`, verified against audited resources at publish |
| **Inputs** | `ash:input name= from=` — FEEL, validated at publish | same | `guard` — a FEEL boolean over the event context |
| **Outputs** | `ash:promote name= [from=] [required=]` — scalars onto `Token.routing`; `from` names an output and defaults to the signal name (not FEEL, per Phase 1 implementation) | same | `correlation` — a FEEL key expression; plus promoted variables into routing |
| **Semantics live in** | the decision definition | the action | the audited action that emitted the event |

One grammar, three seams — a designer who has learned any one of them has learned all
three.

## Per-element notes

**Message start (Phase 2).** The subscription is data: versioned, published, immutable —
everything the app's `Trigger` already is (`event-triggered-processes.md` §4). A message
start event and a trigger are the same object viewed from two sides; the library presents
the diagram as the authoring surface and keeps the row as the deployed artifact.

**Message catch (Phase 3).** The one new interpreter concept: a token whose status is
`waiting`, carrying `(node_id, correlation_key, subscription_ref)`. Delivery claims the
token through the existing single-winner claim gate, so redelivery-safe by construction.
The waiting token's subscription is *instance-local* and therefore pinned to the
instance's definition version — no cross-version subscription drift is possible.

**Timer (Phase 3).** User-task timers already exist as config (`remind / escalate / expire`
kinds, Oban jobs, cancelled on completion). Phase 3 generalizes them into a `TimerJob`
resource any node can own, and promotes `expire` to the diagram as an interrupting timer
boundary. The existing expiry-routing defect (first outgoing flow wins, conditions
ignored — `timer_worker.ex:143-146`) is fixed by making expiry route through the same
gateway code as completion; see `05-hygiene.md`.

**Error end and boundary (Phase 3, route-only).** Today a failed action retries on Oban
and then fails the instance with an `:action_failed` event
(`interpreter.ex:302-304`, `advance_worker.ex:397-411`). The target: failures carry a
*code* (from the action's error, or an `ash:errorCode` declaration on the node); an error
end event types the failure deliberately; an error boundary on a scope routes on that code
to a recovery path. The boundary routes. It never retries — retries are Oban's, bounded by
`max_attempts`, exactly as today (decision 5).

**Signals (Phase 4, durable-log-only).** A signal throw writes an event row of kind
`signal` with a signal name; the sweep delivers it to every matching subscription —
broadcast, not consumed, Zeebe semantics. Because the log is the medium, a signal is
durable, replayable, and ordered with every other event. Phoenix.PubSub is not involved in
delivery (decision 3); whether a host mirrors signals to PubSub for its UI is the host's
business.

**Conditional catch (Phase 4).** A subscription on subject updates whose guard is a FEEL
predicate over the subject. The engine derives which context paths the predicate reads by
walking the boxic FEEL AST (identifiers and path nodes), the Zeebe conditional-event
design; derivation is an optimization for the interest index, not a correctness
dependency.

**Escalation (Phase 4).** `AssignmentResolver.escalate/2` already exists and already
fires from the timer worker. Phase 4 generalizes it: an escalation is a signal with a
named audience, and "start an escalation process" is a signal start event on that name.
The swallowed-exception rescue is fixed first (`05-hygiene.md`).

**Event sub-process (Phase 4).** An instance-scoped subscription set with interrupting /
non-interrupting semantics — cancels the hosting scope or runs alongside it. This is the
mechanism, not a new one: the same waiting-token state, with the subscription's owner
being a scope instead of a token.

**Call activity (Phase 5).** Start a child instance and wait for its completion event —
message catch where the message is the child's completion. This makes "process as action"
real and is the last structural piece.

**Multi-instance (Phase 5).** A FEEL list expression over the subject fans out tokens
(sequential or parallel) that join on completion. The line-item-approval story, and the
one Phase-5 item most likely to be pulled forward by demand.

**Subject loads (Phase 3).** Designers can declare `ash:load` on a gateway or task naming
relationships/calculations the node's expressions need; the engine loads them strictly
(paths not loaded read as `nil` in FEEL, which is the existing missing-path semantics).
This keeps "read the live subject" while ending the choice between loading everything and
hand-writing FEEL over a starved context.
