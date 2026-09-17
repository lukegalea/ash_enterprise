# Research findings — the evidence base

Condensed findings from the research pass of 2026-09-06, kept here so the PRD and TRD can
cite them without re-derivation. Five lanes: the engine, the FEEL/DMN layer, the host
app and Ash core, the ecosystem's reactive primitives, and Camunda/Zeebe prior art.
Claims carry file:line references as found on that date; line numbers drift.

## 1. ash_bpmn — what exists

**The executable subset is seven node types** — `startEvent, endEvent, userTask,
serviceTask, businessRuleTask, exclusiveGateway, parallelGateway`
(`lib/ash_bpmn/compiler/xml.ex:13`) — plus `sequenceFlow` with FEEL conditions stored as
`%{"language" => "feel", "text" => ...}` source text.

**Collection vs refusal.** Nodes are collected by an any-depth XPath over the seven type
names (`xml.ex:206-214`); refusal walks only *direct* `bpmn2:`-prefixed children of
`<process>` (`compiler/graph.ex:83-119`, refusal branch `102-112`, silent-ignore
fall-through `114-117`). Consequences: nested event definitions on supported nodes are
silently ignored (start `graph.ex:328-330`, end `graph.ex:275-321`); `bpmn:`-prefixed
unsupported elements slip the refusal (`graph.ex:102` vs the normalizer at
`xml.ex:253-256`); collaboration/messageFlow and root-level message/signal/error
definitions under `<definitions>` are never scanned; multiple `<process>` elements are
refused (`xml.ex:58-60`); `isExecutable="false"` refused (`graph.ex:16-21`).

**Four host seams, not three** (`config :ash_bpmn`): `ActionInvoker` — `invoke(action,
ctx) :: :ok | {:ok, map()} | {:error, term()}`, ctx = instance/token/subject/assigns/scope
(`action_invoker.ex:19-20`, built `runtime/advance_worker.ex:256-273`); `AssignmentResolver`
— candidates/exclusions/escalate, specs normalized to opaque string maps
(`assignment_resolver.ex:55-105`); `DecisionResolver` — `decide(ref, inputs, ctx)` +
publish-time `exists?/1`, inputs already FEEL-evaluated by the engine
(`decision_resolver.ex:73-100`, `compiler/verify.ex:46-98`); `DefinitionLoader` —
tenant-scoped definition loading (`definition_loader.ex:50-106`).

**Service-task binding is one opaque string** — `ash:taskConfig action="..."` is the only
permitted ash attribute (`graph.ex:215-227`), one free-text field in the panel
(`web/designer_live.ex:649-663`), straight to the invoker at runtime
(`runtime/interpreter.ex:269-276`). The same invoker serves standalone approvals'
`on_complete` refs (`ash_bpmn.ex:260-279`).

**Runtime.** Advance loop on Oban with a single-winner token claim (`StatusIsActive` +
`EnsureActiveInDb` + `IncrementAttempts`, `resources/token.ex:156-300`); lost races and
stale redeliveries are no-ops (`advance_worker.ex:61-125`). Tokens wait only two ways:
parked user tasks (`interpreter.ex:345-351`) and joins, released when all `waits_for`
arrive *or* no active sibling tokens remain — dead-branch reconciliation
(`advance_worker.ex:147-206`). Timers are per-task Oban jobs (remind/escalate/expire,
`interpreter.ex:538-545`), cancelled on completion and cancel (`ash_bpmn.ex:214-217`,
`449-452`); expiry force-completes and advances down the *first* outgoing flow, ignoring
conditions and default (`timer_worker.ex:143-146`); escalate rescues everything
(`timer_worker.ex:64-92`). Failures raise → Oban retry → instance `:failed` after
`max_attempts` (`interpreter.ex:302-304`, `advance_worker.ex:397-411`); recovery is
manual `retry_instance!` (`ash_bpmn.ex:550-585`); a `SweepWorker` recovers orphaned
tokens as `:sweep_recovered`. **No message delivery API exists**; `correlation_id` is
set at start and never read (`ash_bpmn.ex:85-89`). Engine authority goes through
`AshBpmn.Scope.engine/2` + the `AshBpmnInteraction` bypass; the one `authorize?: false`
is subject reads (`scope.ex:171-194`), enforced by a build-failing test.

**Facade.** `start_instance!/2, complete_task!/2, decide!/2, claim_task!/2,
delegate_task!/2, cancel_instance!/2, my_tasks/2, instance_report/2, retry_instance!/2`
(`ash_bpmn.ex`). `complete_task!` re-implements gateway routing in the facade
(`ash_bpmn.ex:633-740`) and consumes tokens with raw SQL (`842-865`); `my_tasks/2` is
N+1 (`485-503`).

**Designer.** bpmn-js Modeler/Viewer via a Phoenix hook; hook↔LV protocol of
save/collect/apply-config (`priv/js/ash_bpmn_designer.js:328-480`); a custom moddle
descriptor round-trips the ash vocabulary (`js:47-171`); the server-rendered panel covers
serviceTask (one field), userTask (candidates/outcomes/exclusions/timers), endEvent
(outcome) — **everything else shows "No configurable properties"**, including gateway
conditions and businessRuleTask bindings (`designer_live.ex:649-777`).

**Snapshot.** `Definition.graph` = `%{"process_id", "start", "nodes" => %{id => type +
config}, "flows", "joins"}` (`compiler.ex:14-29`); conditions are source text validated
by `Boxic.FEEL.parse/1` at publish; `AshBpmn.Feel` wraps `boxic_feel ~> 0.2` with a 250 ms
kill-timeout and no parse cache (`feel.ex:89-181`).

## 2. FEEL and DMN — what the expression layer can do

- **`AshDecisions.Feel.evaluate/3` evaluates an arbitrary FEEL string against a context
  map, standalone, sandboxed** (250 ms process-kill, 4096-byte and depth-32 caps; no
  external functions, structurally) — `ash_decisions/lib/ash_decisions/feel.ex:96-192,
  390-450`. Parse is memoized in `:persistent_term` keyed by source hash, write-once,
  capped (`feel.ex:432-450`).
- **The boxic AST is public** (`boxic_feel/lib/boxic_feel.ex:11-32`) with
  `parse/1` and `evaluate_ast/2,3` — parse once, evaluate many, the right shape for a
  subscription router. `{:identifier, name}` / `{:path, src, name}` nodes are the
  referenced-path set; no path-extraction helper ships (~20-line walk, minding
  `for`/quantifier bindings). Unary tests (`< 10`, `"a","b"`) have **no** parse-only API —
  parsed inside the evaluator per call, not cacheable.
- **Language coverage**: comparisons over Decimal/temporals/strings; Kleene three-valued
  and/or/not; ranges and `in`/`between`; `matches()` with real PCRE and FEEL flags
  `simxq`; string/list/number/temporal builtins (96 names, `builtins.ex:8-95`) including
  all 13 Allen relations; quantifiers, `for`, filters, `if`, function literals,
  `instance of`. Missing-path is `nil`, not an error; **type mismatch raises
  `{:error, :type_error}`** (evaluator `:735-736`) — event contexts must be normalized
  through `to_feel_value/2` (ints/floats → Decimal) or subscriptions error on dirty
  events.
- **Null discipline**: FEEL `null` under ordering comparison is `nil` (not `false`); DMN
  tables treat it as no-match; a subscription engine must define nil ⇒ no-match
  explicitly. No windowing/sequencing — FEEL is stateless per evaluation.
- **boxic_dmn** targets DMN 1.5; ash_decisions executes only `decisionTable` and
  `literalExpression` and refuses `RULE_ORDER`/`OUTPUT_ORDER` (`compiler.ex:87-98`);
  the snapshot (`Definition.graph`, `compiler.ex:512-608`) stores FEEL source text and
  **stamps the engine versions** — the pattern the BPMN snapshot should copy.
- Evaluation is `AshDecisions.Evaluator.evaluate/3` (no Ash action; model memoized by
  `content_hash`); `matched_rule_ids` is always `[]` (the engine does not report it).

## 3. Host app and Ash core — the surfaces that exist

- **The app already has event-triggered processes** (`lib/ash_enterprise/process/`):
  versioned `Trigger` (match + `guard_feel` + DMN `decision_key` or `process_key` +
  `max_starts_per_event`), `TriggerCursor` (per-tenant `last_sequence`), `TriggerDispatch`
  (`identity :once_per_event, [:trigger_id, :event_id]`, `trigger_dispatch.ex:129`), a
  notifier nudge (post-commit, debounced Oban insert per tenant, everything rescued,
  `triggers/notifier.ex:42-57`), a minute `CronSweep`, a cursor'd `SweepWorker`
  (lock tenant, batch 500, dispatch per event in its own transaction), a three-stage
  funnel in `Dispatch` (match → guard → DMN route → `AshBpmn.start_instance` at
  `dispatch.ex:194`), and an ETS interest index. Full rationale, measurements, and
  failure semantics in [`docs/plans/event-triggered-processes.md`](../plans/event-triggered-processes.md).
- **The audit log**: `AshEvents.EventLog` with per-tenant `pg_advisory_xact_lock` before
  insert ⇒ within a tenant, `sequence` order = commit order (measured; the NULL-tenant
  chain shares no lock space and has no guarantee). DB triggers enforce append-only +
  a SHA-256 hash chain (`audit/event_log.ex:85-231`). AshEvents works by wrapping every
  CUD action as a manual action writing the row in-transaction — **no notifiers, no
  push**; replay is a cold synchronous rebuild.
- **Ash notifier seam**: `%Ash.Notifier.Notification{resource, domain, action, data,
  changeset, actor, for, from, metadata}`; built post-action, buffered in the process
  dictionary while in-transaction, flushed **after commit, synchronously in the caller's
  process** (`deps/ash/lib/ash/changeset/changeset.ex:4664-4756`,
  `notifier/notifier.ex:183-224`). `Ash.Notifier.PubSub`: declarative topics with
  tenant/pkey interpolation, old+new values on update, in-memory broadcast.
- **ash_oban**: triggers are cron polling of resource *state* through an `Ash.Expr`
  `where` filter with keyset streaming (`transformers/define_schedulers.ex:57-192`);
  push exists only as explicit `run_trigger/run_triggers` or the `run_oban_trigger`
  change. No event semantics.
- **ash_state_machine / ash_paper_trail**: state machine emits nothing distinct
  (transitions are ordinary updates; the platform base generates one named action per
  lifecycle transition, so transitions *are* audited); paper trail writes versions
  in-transaction via `after_action` with no push channel, and is **dormant** in this app
  (ADR 0002: one central log).

## 4. Prior art — Camunda 7 vs Camunda 8 (Zeebe), with sources

- **Correlation**: C7 correlates by querying executions/definitions over variables at
  publish time (message name + business key + correlationKeys map;
  camunda.org/manual/7.21 message-events). Zeebe opens a **subscription at element
  activation** with a **correlation-key FEEL expression evaluated once and frozen**
  ("not updated" afterwards); messages carry TTL and are **buffered**; an optional
  **message ID** gives idempotent publish; a message correlates **once per process id
  across versions** (non-deterministic winner by design); across different processes,
  all matching subscriptions (camunda.io docs: messages).
- **Buffering**: Zeebe TTL buffer, FIFO, polled by new subscriptions; C7 documents none.
- **Start events**: C7 — none/timer/message/signal/conditional at process level;
  error/escalation only in event sub-processes; Flowable requires message start names
  unique across all definitions. C8 — conditional start via API; FEEL timer definitions.
- **Conditional events**: C7 — JUEL + opt-in `variableName`/`variableEvents`. C8 —
  **FEEL conditions with engine-derived variable dependencies from the expression**
  (static analysis at activation decides what triggers re-evaluation; no delete trigger).
  C8's conditional design is the direct prior art for "subscription predicate as a
  declarative expression".
- **Business rule tasks**: C7 `decisionRef` + binding (`latest/deployment/version/
  versionTag`) + `mapDecisionResult` mappers; C8 `calledDecision` (decisionId may be a
  FEEL expression) + single `resultVariable`, shaping via FEEL output mapping — **the
  ash_bpmn `ash:decision` + `ash:promote` shape is C8's**, already.
- **Service tasks**: C7 embedded delegates *or* external workers; C8 **job workers only**
  — diagram carries type + headers, host implements, at-least-once, idempotent by
  contract. `ash:call` is this pattern with code interfaces as the worker.
- **Signals**: broadcast to all handlers, not consumed; C7 synchronous same-transaction;
  C8 async across partitions with a scaling caution; Flowable adds non-standard
  `scope="processInstance"` because global-only broadcast is too blunt.
- **Event-log-driven instantiation**: Zeebe's documented *message aggregation* and
  *single instance* patterns (correlation key = entity id; first event creates,
  subsequent correlate; post-completion events start a new instance); the C8 Kafka
  consumer connector (activation-condition FEEL filter + correlation-key extraction +
  message-ID dedup, offsets committed on success) is productized prior art for
  "subscribe to a business event stream and let correlation drive processes".

**Table stakes distilled** (lib-1's conclusion, adopted by the vision): declarative
subscriptions with a correlation-key expression + durable buffering + dedup; message
start events that instantiate when nothing waits; event sub-processes; broadcast signals
distinct from correlated messages; an out-of-engine task-execution contract (type +
config, host-implemented).
