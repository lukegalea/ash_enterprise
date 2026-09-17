# PRD — The BPMN event dimension

> **Status: requirements, not built.** Derived from the vision documents in this
> directory and the evidence in `research-findings.md`. Requirements are numbered for
> citation: `FR-x.y` (functional), `G-x` (guarantee), `OR-x` (operational), `SR-x`
> (security), `NG-x` (non-goal). Phases refer to `06-roadmap.md`. Decisions `D1`–`D5`
> are those recorded in the `README.md`, 2026-09-06.

## 1. Problem

Processes start only when code calls `start_instance!`, and once running they can only
wait for a human. Business reality is event-shaped: a payment lands, a policy lapses, a
threshold is crossed — and a process should begin or resume on that fact, without a
developer wiring that particular event to that particular process. The application
already built this once, app-level (`AshEnterprise.Process`); the requirement is to make
it a first-class capability of `ash_bpmn`, exposed to process designers, with the same
discipline the engine applies everywhere else: versioned artifacts, publish-time
verification, and the architectural line — *the graph orchestrates; it never decides,
validates, or authorizes*.

## 2. Users

- **Process designers** author diagrams: when this starts, what waits for what, which
  action runs, which decision routes. They work in the designer UI, not in XML.
- **Platform engineers** expose actions (`callables`), provide the `EventSource` adapter,
  and operate the sweep.
- **Auditors** ask *why did this process start, who advanced it, what did it do* — and
  get answers from rows, not from logs.
- **Operators** disable a misfiring subscription at 2am and watch lag.

## 3. Capabilities and functional requirements

### C1 — Honest compilation *(Phase 1)*

The engine must never accept a diagram whose semantics it does not implement.

- **FR-1.1** Any BPMN element or attribute the compiler does not implement — at any
  nesting level inside `<process>`, including children of supported nodes (event
  definitions, loop characteristics, data associations) — is a publish error naming the
  element id and the construct.
- **FR-1.2** Prefix normalization (`bpmn:` vs `bpmn2:`) precedes classification; refusal
  is prefix-independent.
- **FR-1.3** Elements under `<definitions>` outside `<process>` (collaboration,
  messageFlow, root event declarations) that the engine ignores are reported as
  warnings, not silently dropped, when they reference elements of the process.
- **FR-1.4** The snapshot records the `boxic_feel` engine version that validated at
  publish (hygiene #10).

### C2 — Complete designer authoring *(Phase 1)*

- **FR-2.1** Gateway sequence-flow conditions are editable in the designer, with FEEL
  validation feedback at edit time and `:condition_null` surfaced as a diagnostic.
- **FR-2.2** `businessRuleTask` bindings (decision ref + binding + version, inputs,
  promote signals) are authored through the properties panel, not XML.
- **FR-2.3** Unknown-element publish errors (FR-1.1) are displayed in the designer with
  the offending element highlighted.

### C3 — Event-triggered instantiation *(Phase 2)*

- **FR-3.1** A **definition-level subscription** — authored as a diagram's message start
  event or as a standalone router — matches audited writes by resource and (optionally)
  action, filters with a FEEL guard, identifies the subject with a FEEL expression
  (`subject_of`, default `event.record_id`), and starts a process: a static `process_key`
  or a DMN routing decision returning `{process_key, variables} | :no_process`.
- **FR-3.2** Subscriptions are versioned artifacts: `:draft | :published | :retired`,
  one-way publish, plus a mutable `enabled` switch that is **not retroactive** — events
  behind the cursor still fire when the sweep reaches them, and the docs say so.
- **FR-3.3** DMN routing records the fired rule on the dispatch row.
- **FR-3.4** A subscription whose match resource carries no audit hook is refused at
  publish, resource named. A subscription matching an `ash_bpmn` or `ash_decisions`
  resource is refused at publish, resource named (the cycle invariant) — with one
  declared exception: the engine's own signal resource (C6).
- **FR-3.5** Both authoring shapes work and produce the same row: diagram-embedded
  (publishing the definition upserts its linked subscriptions) and standalone (managed
  by its own actions, routed by decision).

### C4 — Action invocation from diagrams *(Phase 2, D2)*

- **FR-4.1** A service task may bind `ash:call ref="Domain.name"` to an action exposed
  in a domain `callables` block. The ref is verified at publish; failure names the ref.
- **FR-4.2** Inputs are FEEL expressions bound to the action's declared arguments;
  anything else fails compile. Outputs cross back only as promoted routing scalars.
- **FR-4.3** The designer's service-task panel lists exposed callables (name +
  description) as a dropdown and argument rows as the input palette.
- **FR-4.4** Nothing not declared in a `callables` block is invokable from any diagram.
  There is no reflective discovery (NG-4).
- **FR-4.5** `ActionInvoker` continues to work unchanged for non-exposed work and
  `on_complete` approvals.

### C5 — Waiting *(Phase 3)*

- **FR-5.1** A token can wait for an event: a message catch node parks its token with a
  correlation key (FEEL, evaluated once over the subject at park time, frozen). A
  matching event (same resource/action match + guard, computed key equal, both non-null)
  claims the token and advances it.
- **FR-5.2** A token can wait for a duration: timer catch nodes and interrupting timer
  boundaries on user tasks, via cancellable timer jobs. User-task `expire` config is
  promoted to the boundary vocabulary without losing behaviour.
- **FR-5.3** Timer-triggered transitions evaluate outgoing conditions and honor the
  declared default, exactly like completions (hygiene #3).
- **FR-5.4** Error end events fail the instance with a typed code. Route-only error
  boundaries (D5) on a scope catch an error class (optionally a code) and route to a
  recovery path; they never retry — retries are Oban's, bounded by `max_attempts`.
- **FR-5.5** A terminate end event kills all sibling tokens.
- **FR-5.6** Gateways and tasks may declare `ash:load` naming relationships/calculations
  their expressions need; loads are strict and unloaded paths read as `nil` in FEEL.
- **FR-5.7** A catch subscription may declare `lookback` (minutes). On entering wait,
  the sweep re-scans that window of history, so an event that arrived just before the
  token waited still delivers — the durable equivalent of Zeebe's TTL buffer. Default 0:
  BPMN-strict, early events are missed.

### C6 — Broadcast and scoped reactions *(Phase 4, D3)*

- **FR-6.1** A signal is a durable event row with a name, thrown by a diagram node or
  by host code through one audited action. Delivery is broadcast to every matching
  subscription; a signal is not consumed on catch. Delivery never touches
  Phoenix.PubSub; a host may mirror for UI, which is the host's business.
- **FR-6.2** Signal start and signal catch events work as C3/C5 with a signal-name
  match instead of resource/action.
- **FR-6.3** Conditional catch: a subscription on subject updates whose FEEL guard is
  evaluated over the live subject; re-evaluation on events touching the subject's
  resource, with dependency paths derived from the expression as an index optimization
  only.
- **FR-6.4** Escalation generalizes the assignment-resolver seam: an escalation is a
  signal with a named audience; escalate-to-process is a signal start event. Resolver
  failures are recorded (`:escalate_failed`), never swallowed (hygiene #6).
- **FR-6.5** Event sub-processes: instance-scoped subscription sets, interrupting
  (cancels the hosting scope) or non-interrupting (runs alongside), on the C5 waiting
  mechanism. Non-interrupting timer boundaries included.

### C7 — Structural composition *(Phase 5, conditional on named use cases)*

- **FR-7.1** Call activity: start a child instance and wait for its completion.
- **FR-7.2** Multi-instance: a FEEL list expression fans out tokens, sequential or
  parallel, joining on completion.
- **FR-7.3** Send/receive task sugar over throw/catch.

## 4. Semantics (cross-cutting)

- **S-1 Event context is a published contract** — the map of `event`/`actor`/`tenant`/
  `data`/`changed`/`metadata` (`03-event-backbone.md`). Breaking changes are
  version-marked and migration-noted, never silent.
- **S-2 `data` is a snapshot, not a live read.** Guards are never queries; the started
  process re-reads its subject through Ash. Tokens carry routing, not business data.
- **S-3 FEEL is the only expression language** — guards, subject/correlation keys,
  conditions, lookback. Equality is `=`. **`nil` and `type_error` are no-match,
  uniformly**, and null-guard outcomes are recorded distinctly (`:guard_null`), closing
  the diagnostic asymmetry the gateway already knows about.
- **S-4 Every context value passes `to_feel_value/2` at the boundary** (Decimal
  conversion).
- **S-5 Correlation keys freeze at park time**; subject changes never move a waiting
  token's key. Null keys match nothing.
- **S-6 Aggregator instantiation only (D4)**: first event starts, later events
  correlate, post-completion events start a new instance. This is behaviour, documented,
  not accident. The single-instance guard is sketched and unscheduled.
- **S-7 Actor, tenant, correlation**: event-triggered work runs as the engine actor
  with the originating human in `started_by_id` and the correlation id; human task
  decisions remain the human's. No requester actor context is ever rebuilt in the
  dispatcher.

## 5. Guarantees

- **G-1 Exactly-once per (subscription, event)** for starts and per (waiting token,
  event) for catches — dispatch ledger identity, written transactionally with the
  instance start or token advance.
- **G-2 Ordering**: events are consumed per tenant in ascending sequence; for
  `:commit_order` chains, per-subject ordering follows from per-tenant commit order.
  `:best_effort` chains (the NULL-tenant chain) are dispatched with no ordering promise,
  and say so.
- **G-3 Durability**: no event matched by a published, enabled subscription is lost to
  a crash — the nudge may be lost (at-most-once, post-commit), the sweep never is
  (cursor + identity). A signal is as durable as the log.
- **G-4 Redelivery safety**: event delivery to a waiting token goes through the token
  claim gate; Oban redelivery cannot double-advance. Callable invocations are idempotent
  by contract (already usage rule 12).
- **G-5 Cycle boundedness**: engine and decision resources are refused as match targets
  (except the signal resource), and dispatch carries a bounded `depth` marker so any
  future indirect cycle is bounded, not merely improbable.
- **G-6 A broken subscription never wedges the stream**: the cursor advances past
  events it could not dispatch; the failure is a dispatch row with a reason.
- **G-7 Definitions and subscriptions are immutable-on-publish; in-flight instances pin
  their definition for life** (usage rule 4, extended: instance-level subscriptions are
  pinned by construction).

## 6. Operational requirements

- **OR-1** Cursor lag is a detected condition: `lag_seconds`, health check, telemetry —
  a stalled dispatcher is not a support ticket.
- **OR-2** The failure taxonomy of the plan's §9 is preserved and extended with catch
  rows (`:instance_not_waiting`), each recorded as data.
- **OR-3** Disabling a subscription is immediate for matching, non-retroactive for
  dispatched history, and audited.
- **OR-4** Sweep throughput is observable (events/sec, batch sizes, guard evaluation
  time) and the one-sweeper-per-tenant ceiling is stated, not hidden.

## 7. Security requirements

- **SR-1** Exposure is a reviewed decision: only `callables`-declared actions are
  diagram-invokable (D2); the declared set is the designer's palette.
- **SR-2** Tenant-authored expressions are hostile input: sandbox (kill-timeout, size
  and depth caps, no external functions) everywhere FEEL meets tenant-authored source.
- **SR-3** Engine authority flows through the engine scope and the existing interaction
  bypass — no new `authorize?: false` anywhere; the build-failing test guards this.
- **SR-4** Tenancy: subscriptions, cursors, dispatches, waiting tokens are tenant-scoped;
  the tenant travels in job args and is passed explicitly (usage rule 14).
- **SR-5** Signals thrown by host code carry the throwing actor; signals thrown by
  diagrams carry the engine actor with the originating correlation id.

## 8. Non-goals (refused — re-proposals should cite these)

- **NG-1** Camunda 7-style query-over-variables correlation.
- **NG-2** Data objects / stores / associations; any diagram-level data model.
- **NG-3** FEEL windowing, sequencing, or any CEP semantics.
- **NG-4** Reflective action discovery or auto-exposure.
- **NG-5** Graph-level compensation / undo propagation.
- **NG-6** Retry/backoff contracts in the graph (boundaries route only — D5).
- **NG-7** Global cursors; rebuilt requester actor contexts; guards as live queries.
- **NG-8** Phoenix.PubSub as a delivery path for process semantics (D3).

## 9. Acceptance test themes (per phase exit)

- **P1**: a corpus of legal-in-bpmn.io diagrams containing every refused construct fails
  publish with the element named; designer round-trips conditions and decision bindings.
- **P2**: the app runs on the library engine; end-to-end audited write → dispatch row →
  instance, and the row answers *why*. Cycle refusals fire. Disabled-not-retroactive is
  tested.
- **P3**: claim-race, stale-redelivery, late-event-after-cancel, expiry-honors-default,
  error-boundary-routes-without-retrying, terminate-kills-siblings; lookback delivers an
  early event; lookback 0 does not.
- **P4**: replayed tenant log delivers every signal to every catcher via ledger rows;
  conditional catch fires on subject transition; escalation failure is recorded.
- **P5**: per-item, with the use case that earned it.

## 10. Open questions — settled 2026-09-07

All four settled at Phase 1 review, decisions recorded:

1. **Escalate-failure policy: record-and-continue.** Resolver failures write an
   `:escalate_failed` process event and never interrupt the instance — FR-6.4 as
   written, consistent with the Phase 1 `:timer_cancelled` pattern: engine facts are
   recorded, not raised.
2. **`binding="latest"` decisions in long-lived definitions: publish-time warning**,
   via the warnings mechanism FR-1.3 added to the snapshot — a warning, never a block.
   The FEEL engine stamp (FR-1.4) is the model.
3. **Event-based gateway: included**, riding the Phase 3/4 catch-event machinery — the
   waiting-token claim race already yields first-delivery-wins semantics; no separate
   construct is built.
4. **Inclusive gateway: deferred deliberately.** Its join semantics are now formally
   documented in `ash_bpmn`'s DESIGN.md §6.2 (the join's dead-branch reconciliation
   *is* inclusive-join behavior); promoting it to a shared implementation is a recorded
   decision for the day a use case earns the gateway — not accretion.
