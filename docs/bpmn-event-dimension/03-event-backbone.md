# 03 — The event backbone

The audit log becomes the engine's message bus, and the app's `AshEnterprise.Process`
domain is absorbed into `ash_bpmn` behind a behaviour so the coupling is the host's choice.

## The absorption (decision 1)

What exists app-level today moves into the library; what is genuinely app-specific stays.

| Moves into `ash_bpmn` | As |
|---|---|
| `Process.Trigger` (versioned match + guard + route) | `Subscription` — authored as a diagram's message start event, stored as a deployed row |
| `Process.TriggerCursor` | per-tenant cursor over the `EventSource` |
| `Process.TriggerDispatch` | dispatch ledger, identity `(subscription_id, event_id)` |
| `Process.Triggers.SweepWorker` | the driver: lock tenant → read cursor → batch → dispatch → advance, one transaction |
| `Process.Triggers.Notifier` + cron | the nudge: post-commit hint, minute cron completeness net |
| `Process.Triggers.Index` (ETS) | interest index built from published subscriptions |
| The three-stage funnel, cycle invariant, failure semantics | library semantics, inherited from [`event-triggered-processes.md`](../plans/event-triggered-processes.md) |

| Stays app-level | Why |
|---|---|
| The audit log itself (`AshEnterprise.Audit.EventLog`) | It is the app's data, with its hash chain and immutability triggers |
| Platform baselines and tenant bindings (`Process.Binding`, `Resolver`) | App-specific multi-tenancy concerns; the library takes a resolved definition the way `start_instance/2`'s `:definition` option already does |
| `SystemActor` and correlation-id infrastructure | The library accepts `:correlation_id` and an actor; it does not own either concept |

The app's `AshEnterprise.Process` becomes the reference consumer: it configures the
extension, provides the `EventSource` adapter, and keeps the baseline/binding layer. No
cutover machinery exists in this design — the prototype has never run in production, so
the library lands and the app modules are deleted in the same change (`trd.md` §10).

## The `EventSource` behaviour

The library must not depend on `ash_events`. It depends on this:

```elixir
defmodule AshBpmn.EventSource do
  @callback stream(tenant(), after_sequence, limit) :: {[event()], last_sequence}
  @callback context(event()) :: %{optional(String.t()) => term()}   # the published contract below
  @callback order_guarantee(tenant()) :: :commit_order | :best_effort
end
```

Three obligations, and they are the whole contract:

1. **Stream** events above a sequence, ascending, bounded — the cursor protocol.
2. **Context**: reshape each event into the published context map.
3. **Declare its ordering guarantee per chain.** The reference adapter targets `ash_events`
   and inherits the measured property from the plan (§2): per-tenant
   `pg_advisory_xact_lock` before insert makes sequence order equal commit order *within a
   tenant* — and the NULL-tenant chain shares no lock space at all and is `:best_effort`,
   full stop. A consumer that silently depends on an upstream detail is a consumer that
   breaks silently when it changes; the adapter says so in its moduledoc and the engine
   treats `:best_effort` chains accordingly (dispatch, but never promise per-subject
   ordering on them).

Also inherited, stated in the adapter and not re-measured here: **the log is not a change
feed**. It is a feed of writes that went through an audited Ash action. Raw SQL writes —
the strangler's legacy application — produce no events, and a subscription watching for
one waits forever without erroring, so the reference adapter refuses, at publish time, a
subscription whose resource carries no audit hook, with the resource named
(`event-triggered-processes.md` §2b).

## The subscription model

A **definition-level subscription** (message start event) is a deployed artifact with
`Trigger`'s discipline: `key`/`version`/`status` (`:draft | :published | :retired`),
publish one-way, `enabled` as the separate mutable operational switch — disabling is not
retroactive and the moduledoc says so. Its declarative shape:

```
resource  = "MyApp.Order"            # verified audited at publish
action    = "mark_paid"              # nullable = any action on the resource
guard     = total > 10000 and customer.tier = "gold"     # FEEL boolean over event context
correlate = order.id                 # FEEL expression over event context → subject
route     = decision_ref | process_key                   # DMN routing or static
```

An **instance-level subscription** (message catch, signal catch, conditional catch, event
sub-process) is a row owned by a waiting token or an instance scope. It is pinned to the
instance's definition version by construction — no cross-version subscription drift is
possible, which is rule 4's spirit applied to subscriptions.

**Routing through a decision** stays first-class, as the app built it: the route stage is
a DMN decision mapping event context → `{process_key, variables} | :no_process`, with the
fired rule recorded on the dispatch row. Process *selection* logic lives in versioned
decisions — not in code, not in the graph. The guard is an expression, the routing is a
decision table: the DMN-idiomatic decomposition, carried forward unchanged.

## Correlation

Zeebe's model, adapted (Camunda 7's query-over-variables is refused):

- A catch subscription's **correlation key is a FEEL expression evaluated once, when the
  token enters waiting** — over the instance's subject context — and frozen onto the
  waiting token. Never re-evaluated; a later subject change does not move a waiting
  token's key.
- The engine computes an event's key with the subscription's `correlate` expression over
  the event context, and delivers when the two are equal (both must be non-null; null
  matches nothing).
- Start events use the same expression to identify the *subject* of the new instance —
  the record the event happened to, `record_id` by default.

**Events that arrive early.** Zeebe buffers messages for a TTL because it has no log; we
are the log. The cursor has still moved past, so a token that starts waiting *after* an
event would normally miss it — BPMN-strict, and the default. An optional per-subscription
`lookback` window makes the sweep re-scan bounded recent history when a token enters
waiting, which is a TTL buffer implemented as a lookup, with the durability the log
already has.

## Delivery semantics

The inversion the app discovered, inherited as law: **the sweep is the driver, the nudge
is a hint.** The audit table cannot be marked (a Postgres trigger raises on `UPDATE`), so
there is no per-row state to reconcile against and one writer holding a lock walking a
cursor is trivially correct. The nudge exists because Ash defers notifications until after
commit — enqueuing from a notifier is not transactional with the write, so a lost nudge
must cost latency, never correctness, and the cron guarantees it does.

- **Exactly-once per (subscription, event)**: the dispatch identity, written in the same
  transaction as the instance start or token advance. Belt and braces over a cursor that
  already makes duplicates impossible — and the ledger answers *"why did this process
  start?"*, which is the question an auditor actually asks.
- **Per-tenant ordering**: consume ascending, one tenant at a time, under the sweep lock.
  Per-subject ordering follows from per-tenant commit order for `:commit_order` chains.
- **Token safety**: delivery routes through the existing single-winner claim gate
  (`token.ex` claim action), so Oban redelivery cannot double-advance a waiting token —
  the same property that makes service-task redelivery safe today.
- **Waiting on multiple conditions** (event-based gateway, later): first delivery wins the
  claim; siblings are killed, exactly as a branch prune works today.

## The event context is a published contract

Both the guard and any routing decision see the same map, and changing its shape breaks
every tenant's subscriptions — so it is documented and tested as a contract, unchanged
from the app version:

```elixir
%{
  "event" => %{"id", "sequence", "occurred_at", "resource", "action",
               "action_type", "record_id", "version"},
  "actor"  => %{"user_id", "system_actor", "impersonator_id"},
  "tenant" => %{"organization_id"},
  "data" => %{...}, "changed" => %{...}, "metadata" => %{...}   # correlation_id, depth
}
```

**`data` is the event's snapshot, not a live read.** By sweep time the record may have
changed or been archived. A trigger fires on what happened, not on what is now true — so a
guard is never a query, and the process re-reads its subject through Ash at execution
time. Same rule as *tokens carry routing, not business data*, one layer up.

## Actor, tenant, correlation

Inherited verbatim from the plan (§6), because the reasons have not changed:

- An event-triggered process runs as the **engine actor**, with the originating human in
  `started_by_id` and in the correlation id. A process outlives a session; a session's
  authority must not. Rebuilding the requester's actor context in the dispatcher is
  refused — it is a standing privilege-escalation surface.
- **Human decisions inside the process are still the human's**: claiming and completing a
  task arrive on a real request with a real actor.
- **Tenant** comes from the cursor, travels in the Oban args, and is passed to
  `start_instance/2` — usage rule 14 unchanged.
- **Correlation** travels event → dispatch row → `start_instance(correlation_id:)`, joining
  the whole chain back to the originating write.

## The cycle invariant

Some engine and decision resources carry the audit hook (publishing a process and deciding
a task are governance events), so a process started by an event writes an event. The app's
answer becomes the library's rule: **a subscription may not match an `ash_bpmn` or
`ash_decisions` resource** — refused at publish time with the resource named — plus the
`depth` marker in dispatch metadata, bounded, so a cycle through any future indirect path
is bounded rather than merely improbable.

## Failure semantics

A broken subscription must never wedge the event stream. The cursor advances past events
it could not dispatch; the failure is recorded as data:

| Failure | Behaviour |
|---|---|
| Guard raises or returns non-boolean | `:failed`, `reason: :guard_error`; cursor advances. A guard that cannot decide is not a guard that says yes. |
| Decision errors vs no rule fires | Distinguished: `:decision_error` is a bug, `:no_rule_fired` is a modelling gap. |
| No published definition for the key | `:failed`; `start_instance/2`'s message surfaced verbatim on the dispatch row. |
| Subscription disabled | Not matched, nothing recorded, not retroactive. |
| Sweep crashes mid-batch | Cursor unchanged, batch replayed, the identity turns replay into `:skipped`. |
| Cursor falls behind | `lag_seconds` + health check + telemetry — a stalled dispatcher is a detected condition, not a support ticket. |
| Routing fan-out over the bound | `:failed`, `reason: :fan_out_exceeded`. Refusing loudly beats starting 50,000 processes. |
| Catch delivery to a cancelled instance | `:skipped`, `reason: :instance_not_waiting`. The log is not rewound; late events are facts about the past. |

## FEEL discipline

The expression language is FEEL and there is only one (usage rule 9, extended to guards,
correlation keys, and lookback windows). The engine-level invariants:

1. **`nil` and `type_error` are no-match, uniformly.** FEEL's three-valued logic means a
   missing path under `>` is `null`, not `false`; a router that treats it as anything but
   "did not match" is a silently wrong subscription. (The gateway's `:condition_null`
   asymmetry is already a known diagnostic gap — guards record null distinctly.)
2. **Every context value passes `to_feel_value/2` at the boundary.** FEEL numbers are
   decimal; a plain Elixir integer in the context makes every numeric comparison a type
   error — "the single most consequential line" in the FEEL seam, and it applies doubly
   to event contexts, which are full of integers.
3. **Store source text; cache ASTs.** Snapshots and subscription rows keep FEEL source;
   parsed ASTs live in `:persistent_term` keyed by subscription id + engine version and
   flush on upgrade. A tree pins a parser; text pins nothing.
4. **Tenant-authored expressions are hostile input.** Guards use the existing
   process-kill sandbox (250 ms, size and depth caps, no external functions). The
   `Task.async` spawn per sandboxed evaluation is real cost at stream throughput; the
   answer if it bites is a worker pool, not dropping the sandbox.
5. **Path extraction over the AST** (for conditional-catch dependency routing and index
   building) is a small library-owned walk of the public boxic AST — identifiers and path
   nodes — accounting for bindings introduced by `for`/quantifiers. Derivation is an
   optimization; correctness never depends on it.

## Signals: durable-log-only (decision 3)

A signal is an event row of kind `signal` with a name, written through an audited action
(the same path every other fact takes). The sweep delivers it to **every** matching
subscription — broadcast, not consumed; two catchers both fire; Zeebe semantics. What that
buys, stated plainly: a signal is durable (a crashed sweep loses nothing), replayable
(the dispatch ledger says who got it), ordered with every other event in the tenant, and
auditable (who threw it is the action's actor). Phoenix.PubSub is not involved. A host
may mirror signals to PubSub for its UI; that is the host's business and never a delivery
path for process semantics.

## Single-instance-per-key: deferred (decision 4)

The one Zeebe pattern not taken now. The aggregator shape — first event starts the
instance, later events correlate into a waiting one, an event after completion starts a
*new* instance — is the only v1 instantiation behaviour, and it is documented as
behaviour, not accident. When a use case demands "at most one live instance per key", the
design is a partial unique index on active instances `(process_key, correlation_key)` at
start time, with Zeebe's non-deterministic-winner stance adopted explicitly rather than
pretending "oldest wins". Not scheduled; sketched so the PRD can cite it.
