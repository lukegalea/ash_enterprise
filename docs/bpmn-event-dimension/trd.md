# TRD — The BPMN event dimension

> **Status: technical design, not built.** The *how* to `prd.md`'s *what*. Module and
> resource names are proposals for the PRD review; everything else (semantics,
> guarantees, mechanisms) is settled by the vision documents and decisions `D1`–`D5`.
> References to existing code are to `deps/ash_bpmn` unless prefixed.

## 1. Module map

New surface in `ash_bpmn`:

```
AshBpmn.EventSource                      behaviour (§2)
AshBpmn.EventSource.AshEvents            reference adapter (§2.1)
AshBpmn.Domain                           domain extension: callables (§3)
AshBpmn.Resources.Subscription           definition-level subscriptions (§4.1)
AshBpmn.Resources.Cursor                 per-tenant cursor (§4.2)
AshBpmn.Resources.Dispatch               delivery ledger (§4.3)
AshBpmn.Resources.Signal                 signal emission (§4.5)
AshBpmn.Resources.TimerJob               generalized timers (§4.6)
AshBpmn.Triggers.SweepWorker             the driver (§5)
AshBpmn.Triggers.Nudge                   notifier (§5.1)
AshBpmn.Triggers.Index                   ETS interest index (§5.2)
AshBpmn.Triggers.Correlator              funnel + waiting-token delivery (§5.3)
AshBpmn.Runtime.Waiting                  park/wake mechanics (§6)
```

Touched: compiler (`xml`, `graph`, `verify`), interpreter, advance/timer workers,
facade, designer LiveView + moddle descriptor, config.

## 2. `AshBpmn.EventSource`

```elixir
defmodule AshBpmn.EventSource do
  @callback stream(tenant :: term(), after_sequence :: integer(), limit :: pos_integer()) ::
              {:ok, {[event :: term()], last_sequence :: integer() | nil}}
  @callback context(event :: term()) :: %{optional(String.t()) => term()}
  @callback sequence(event :: term()) :: integer()
  @callback occurred_at(event :: term()) :: DateTime.t()
  @callback order_guarantee(tenant :: term()) :: :commit_order | :best_effort
  @callback audited?(resource :: module()) :: boolean()
end
```

`config :ash_bpmn, event_source: MyAdapter` (default `nil`; the triggers extension
refuses to start without one). The adapter owns every coupling to the host's log; the
engine never sees `ash_events` types.

### 2.1 Reference adapter (`AshEvents`)

- `stream/3`: `EventLog` read, `sequence > after`, asc, `limit`, tenant from cursor.
- `context/1`: builds the published contract (S-1) from the event row — `event` (id,
  sequence, occurred_at, resource short-name, action, action_type, record_id, version),
  `actor`, `tenant`, `data`, `changed`, `metadata`. Resource names use the short
  form people type and guards compare against (`event-triggered-processes.md` §2b's
  three-spellings rule; the adapter is where the module atom becomes the short string).
- `order_guarantee/1`: `:commit_order` for real tenants; `:best_effort` for the
  NULL-tenant chain — which shares no lock space with anything (`plan` §2.3) and gets
  no promise. Stated in the moduledoc as a property *of ash_events' implementation*,
  with the pointer the plan requires, so an upstream change is loud, not silent.
- `audited?/1`: resource carries `AshEvents.Events` with the log this adapter reads.
  Publish-time refusals (FR-3.4) call this.

## 3. `AshBpmn.Domain` — callables

Spark domain extension, `ash_ai`-style:

```elixir
use Ash.Domain, extensions: [AshBpmn.Domain]

callables do
  callable :approve_payout, MyApp.Finance.Payout, :approve do
    description "..."          # optional, shown in the designer
  end
end
```

- Entities verified at compile time: resource belongs to the domain, action exists,
  name unique within the domain.
- Introspection: `AshBpmn.Domain.callables(domain)` → `[%{name, resource, action, description}]`,
  plus `callable?(domain, "Domain.name")` — the publish-time check and the designer
  dropdown's data source.
- The callable reference spelling in diagrams is `"Domain.name"` (aliases resolved at
  DSL definition; diagrams never contain module aliases beyond the domain's own name).

**As built (2026-09-07, ash_bpmn PR #6).** The `callables` section builder lives in a
nested child extension `AshBpmn.Domain.Dsl` — Spark generates a `callables/1` section
macro inside the extension module, and Elixir cannot host that macro alongside the
`callables/1` introspection function; hosts are unaffected (`extensions: [AshBpmn.Domain]`
pulls the child in automatically). `callable?/2` resolves `"Domain.name"` and bare
`"name"` refs, and a non-nil first argument constrains resolution to that domain —
mismatches and lookup failures are uniformly `false`. Ref resolution never materializes
atoms from input: it looks up the `Elixir.`-prefixed spelling.

## 4. Resources

All on the host's base via `:base`/`:base_opts` (usage rule 15; the interaction bypass
ordering caveat applies and is documented per-resource). All engine writes go through
`AshBpmn.Scope.engine/2`.

### 4.1 `Subscription`

| Attribute | Type | Notes |
|---|---|---|
| `key`, `version`, `status` | as `Definition` | `:draft \| :published \| :retired`; publish one-way; per-key version sequence under attribute multitenancy (proven: `plan` §8) |
| `enabled` | `:boolean`, default true | Mutable operational switch; not retroactive (FR-3.2) |
| `source` | `:atom` `:start_event \| :standalone` | FR-3.5's duality |
| `definition_id`, `node_id` | nullable | Set when `source: :start_event`; publish upserts by `(definition_id, node_id)` |
| `match_resource` | `:string` (short name) | Indexed coarse key |
| `match_action`, `match_action_type` | `:atom`, nullable | Null = any |
| `kind` | `:atom` `:message \| :signal` | Phase 4 adds `:signal` matching on `signal_name` instead of resource/action |
| `signal_name` | `:string`, nullable | For `kind: :signal` |
| `guard_feel` | `:string` | FEEL boolean; parsed at publish; boolean-ness linted |
| `subject_of` | `:string` | FEEL over event context → subject id; default `"event.record_id"` |
| `correlation_key_feel` | `:string` | For catch-bearing definitions (Phase 3): document + validate, frozen at park |
| `route_kind` | `:atom` `:static \| :decision` | |
| `process_key` | `:string`, nullable | `route_kind: :static` |
| `decision_key` | `:string`, nullable | `route_kind: :decision`; ref verified via `DecisionResolver.exists?/1` |
| `variable_mapping` | `:map` | variable name → FEEL (as the app's Trigger) |
| `max_starts_per_event` | `:integer`, default 1 | Bounds `COLLECT` fan-out |
| `lookback_minutes` | `:integer`, default 0 | FR-5.7 |

Actions: `create`, `publish` (refuses when errors), `retire`, `enable`, `disable`,
`latest_published`, `by_key_version`. Publish-time validations (in order): guard parses
and is boolean-valued; `subject_of`/`correlation_key_feel` parse; `EventSource.audited?`
on `match_resource` (refused, named); cycle invariant — `match_resource` not an
`ash_bpmn`/`ash_decisions` resource, except `Signal`; `decision_key` exists; FEEL engine
version stamped into the stored compiled form.

### 4.2 `Cursor`

One row per tenant: `last_sequence`, `last_dispatched_at`, `lag_seconds` calculation.
`ownership: :none`, `lifecycle?: false`, `audit?: false` — auditing a cursor is noise
(the app's choices, kept).

### 4.3 `Dispatch`

Append-only ledger, one row per delivery attempt outcome:

| Attribute | Notes |
|---|---|
| `subscription_id` \| (`waiting_token_id` for catch delivery) | the "who" side |
| `event_id`, `event_sequence`, `event_occurred_at` | the "what" side; `sequence` indexed |
| `kind` | `:start \| :catch \| :signal` |
| `status` | `:started \| :delivered \| :skipped \| :failed` |
| `reason` | `:guard_null \| :guard_error \| :no_rule_fired \| :decision_error \| :no_definition \| :instance_not_waiting \| :fan_out_exceeded \| :disabled` … |
| `process_key`, `instance_id`, `decision_key`, `fired_rule` | provenance for auditors |
| `correlation_id`, `depth` | cycle bound travels here (G-5) |

Identity: `:once_per_event, [:subscription_id, :event_id]` and a second
`:once_per_token_event, [:waiting_token_id, :event_id]` — partial unique indexes; both
sides of G-1. `audit?: true` on dispatches is *refused* — a dispatch is already the
record of an event; auditing it is a cycle with extra steps.

**As built (2026-09-07, ash_bpmn PR #7).** Concessions to Spark and Ash 3.31: the
one-per-tenant cursor identity is spelled `[:organization_id]` with `all_tenants? true`,
conditional on `tenant?: true` (Spark rejects empty-key identities); `lag_seconds` is a
module calculation and `advance` stamps wall-clock with `require_atomic? false` (no
`date_diff` expression on this Ash); `publish`/`retire` carry `require_atomic? false`
because publish-time verification does not push down. The stored compiled form is a
`compiled` map attribute (source text + `feel_engine` stamp, the Definition-graph
pattern). Guard boolean-ness is a *lint*: provable non-booleans refuse at publish,
context-dependent nulls pass and are recorded at runtime as `:guard_null`. The reason
taxonomy gains `:guard_false`, `:already_dispatched`, `:depth_exceeded` under this
document's "…". The start-event `(definition_id, node_id)` upsert is columns-only — the
definition-publish and sweep lanes own that contract.

### 4.4 Token (extended)

New status `:waiting`. New fields on the token row (routing data, not business data —
rule 5's boundary explicitly includes correlation keys):

- `subscription_signature` — hash of (kind, match_resource, match_action) the correlator
  queries on; partial index on `status = :waiting` + signature + `correlation_key`.
- `correlation_key` — frozen at park (S-5).
- `lookback_until` — `occurred_at` watermark when `lookback_minutes > 0`.
- `parked_at` — for diagnostics and TTL-style queries.

Claim gate: the claim action's `StatusIsActive` validation admits `:waiting` for
delivery claims only (a distinct `:claim_waiting` action, so an advance worker can never
race a normal claim into a waiting token).

**As built (2026-09-17, `ash_bpmn` b800a54).** Three things came out differently, and the
differences are worth stating because the text above is now wrong in each.

`StatusIsActive` was **not** widened. It still admits `:active` and nothing else; a
sibling `StatusIsWaiting` guards `:claim_waiting`. A validation named for the status it
requires, which then admits a second status, is a trap for the next reader — and keeping
the two guards separate is what actually delivers the property the paragraph wanted: the
two doors cannot be confused at the call site or in the audit log.

The index is `(subscription_signature, instance_id)` partial on `status = 'waiting'`, not
signature plus `correlation_key`. The signature is the coarse equality filter the
correlator always has; the correlation key is compared per candidate once the set is
already small, so putting it in the index costs write amplification on every park and buys
nothing on the read. The tenant copy leads with `organization_id`, which `AshPostgres`
prepends automatically under attribute multitenancy. It is declared in the resource's
`custom_indexes` rather than only in a migration, because a host gets its schema from
`mix ash.codegen` and an index living only in `ash_bpmn`'s own test migrations would reach
nobody's production database.

Leaving the waiting state **clears** all four fields, on the transitions back into a
running state (`claim_waiting`, `reactivate`) and deliberately not on the terminal ones. A
consumed token that still says it waited for `invoice-42` is history and its status says
the wait is over; a token that is `:executing` while still advertising a correlation key is
a claim about the present that is not true. What woke a token belongs in the event log.

Consume and kill both admit a waiting token. An interrupting boundary, a terminate end
event and a cancelled instance all prune live branches, and a parked token is a live
branch; a waiting state that could only be left through its own event would make all three
impossible to implement.

**Known defect, not fixed here.** `:dead` is overloaded. A parallel join kills the tokens
it merges, so "cut off by a terminate" and "merged into a join" are the same status on the
row. A branch that reached its join finished; a terminated branch did not. Today only the
event log distinguishes them.

### 4.5 `Signal`

Minimal emission resource: `name` (indexed), `payload` (:map, size-bounded), tenant.
One action: `emit`. Signal throw nodes call it through the engine scope; hosts call it
directly (`AshBpmn.emit_signal/3` facade). It sits on the host's audited base, which is
the entire point — **a signal is an event row in the host's log, ordered with everything
else** (D3). It is the one named exception to the cycle refusal: subscriptions may match
`Signal`, and cycles through it are bounded by the `depth` marker (G-5), which is what
the depth bound was built for.

### 4.6 `TimerJob`

Generalization of the per-task timer jobs (`interpreter.ex:538-545`,
`advance_worker.ex:371-395`): `owner_kind` (`:task \| :token \| :instance_scope`), owner
ids, `kind` (`:remind \| :escalate \| :expire \| :catch \| :boundary \| :boundary_no_interrupt`),
`run_at`, `payload`, `oban_job_id`, `status`. One cancellation path for all owners —
completion, cancel, branch prune, boundary interrupt; usage rule 6's discipline applied
uniformly. `:timer_cancelled` events emitted here (hygiene #7).

**As decided (2026-09-17, after an Oban capability review).** The shape above survives, but
its *justification* changes, and with it one word that matters: `TimerJob` is a **record**,
never a scheduler. Verified against the vendored Oban 2.23.1 source (OSS; this project has no
Pro licence and must not design against Pro features).

*What Oban already does, and this must not reimplement.* Durable scheduled execution at any
horizon — a `scheduled` row is touched by neither the Pruner nor the Lifeline, so a six-month
timer is safe. The promotion loop (`Oban.Stager`, leader-elected, ~1 s resolution, so "fire at
exactly T" is not on offer at any price and a timer never fires *early*). Retry and backoff.
A best-effort kill broadcast on cancel. And — the discovery that removes a table we were about
to build — **GIN indexes on `args` and `meta`** (`migrations/postgres/v10.ex:39-40`), so
`Oban.cancel_all_jobs(Oban.Job.query(meta: %{token_id: id}))` is an indexed containment query.
Cancel-every-timer-this-token-owns needs no id list of ours.

That retires the `timer_job_ids` pattern for new work rather than generalizing it, and closes a
window rather than widening one: that pattern inserts the jobs, *then* writes their ids to a
row, and a crash in between leaves live jobs nothing can name — the task is decided, the
escalation clock is not stopped, and no `:timer_cancelled` event records it. Writing the owner
*into* the job closes it, because the identifying data lands in the statement that creates it.

*What Oban will not do, which is the entire reason this resource exists.*
`Oban.Plugins.Pruner` deletes `completed`, `cancelled` and `discarded` rows `max_age` after
they land there — **60 seconds by default**. Within about ninety seconds of a timer firing *or
being defused*, the row is gone; `Repo.delete_all`, not archived. So *"did the four-hour
escalation fire, or was it cancelled when the task was reassigned?"* has no answer from Oban,
and `cancelled` carries no reason at all — "task completed first", "instance terminated" and
"timer rescheduled" collapse into one state. Raising `max_age` is a global table-size lever
over every job in the system, not a retention policy; `DynamicPruner`, which could carve out a
per-worker rule, is Pro. (The host now configures a 7-day Pruner, which makes this concrete
rather than hypothetical.)

*Consequences for the fields.* `oban_job_id` stays, as a pointer to the execution substrate and
not as a handle we rely on — a pruned id resolves to nothing and `cancel_job/1` on it returns
`:ok` having done nothing, indistinguishable from success. `status` gains a **`cancel_reason`**,
because that is precisely the distinction Oban's `cancelled` cannot carry. The timer's
definition as authored is recorded alongside its resolved `run_at`, since the audit question is
usually about the definition.

*Three traps the implementation must honour.* (1) A unique insert that cannot take its advisory
lock returns `{:ok, %Job{conflict?: true, id: nil}}` **having written no row** — read as "armed",
that silently loses a timer and strands a token forever. (2) Cancelling an *executing* job is
best-effort and loses the race when the job completes first, so **every timer handler must
re-validate its owner's state at the top of `perform/1`** and return `{:cancel, reason}`;
cancellation is an optimisation, the guard is the correctness mechanism. (3) `insert_all` does
not honour `unique:` on the Basic engine — insert timers one at a time.

*And one road not taken.* AshOban is the wrong shape and is not used here: its trigger model is
a cron-polled predicate scan ("eventually process every record matching this filter"), not
"wake this one token at this instant"; its generated workers hardcode `unique: [period:
:infinity, states: :incomplete]` with no keys, so a re-insert with a later `scheduled_at`
silently returns the *original* job rather than rescheduling; and it has no cancellation API at
all. `AshBpmn.Scope.to_job_args/2` already does the one thing worth borrowing.

*Test mode.* `Oban`'s own `testing:` modes strip the stager entirely, so nothing promotes a
scheduled job and time does not pass. `AshBpmn.Runtime.Oban.TestJobs.fire_due!/1` is the
virtual clock that makes "the reminder fires before the escalation" and "nothing fires early"
assertable; before it, `fire!/2` matched on kind and never read `scheduled_at`, so a
thirty-minute timer scheduled thirty seconds out passed every test in both repositories.

**As built (2026-09-18, `ash_bpmn` 19564eb).** The resource exists and the record/scheduler
split held. Two departures from the shape above, both simplifications.

There is no `owner_kind`. A timer belongs to some subset of an instance, a token and a task,
and it is any subset rather than one of three kinds: a catch timer has a token and no task, a
standalone approval's timer has a task and neither instance nor token. Nullable columns for
each say that directly; a discriminator would have had to enumerate combinations that are not
really alternatives.

`kind` is `:remind | :escalate | :expire | :catch` -- what `TimerWorker` and
`CatchTimerWorker` actually handle. `:boundary` is absent because boundary timers are
cancelled through Oban's `meta` index rather than through the ledger, and
`:boundary_no_interrupt` because non-interrupting boundaries are refused at compile time.

Registered as an **optional kind** beside the trigger kinds rather than a seventh core one: a
host that never draws a timer should not carry a table for them, so `resources.timer_job` is
`nil` there and every writer treats that as "not installed".


## 5. The sweep and the correlator

```
audited write ──▶ event row (seq N, tenant T)
                      │ Nudge (Ash.Notifier, post-commit, rescue-all)
                      │   hit only: ETS index {resource, action_type} → enqueue
                      ▼
        Oban.insert(SweepWorker, %{tenant: T}, unique: [period: 5, keys: [:tenant]])
                      │
   Oban cron (60s) ──┘
                      ▼
   SweepWorker:  pg_advisory_xact_lock(:bpmn_sweep, T)
                 cursor → stream(limit: 500)
                 for each event (asc):
                   Correlator.dispatch(event)
                 advance cursor — same transaction as the batch's dispatch rows
```

One writer, holding a lock, walking a cursor: trivially correct, because the log cannot
be marked (plan §3's inversion — inherited, not reinvented). No transactional outbox:
the cursor already answers "was this processed".

### 5.1 Nudge

An `Ash.Notifier` attached to the event log resource by the host (config, not
convention — the library never touches the host's resource). Post-commit, rescues
everything, debounced Oban insert per tenant. Losing it costs latency, never
correctness (G-3). **Property found in adoption testing:** the nudge is
*resource-coarse* — subscriptions narrowed by `match_action_type` are invisible to it,
and cron covers them; latency, never correctness.

### 5.2 Index (ETS)

Built from published `:enabled` subscriptions: `{match_resource, action_type?}` →
count. Zero hits → the event costs nothing further. Invalidated on publish/retire/
enable/disable (via PubSub in the host app, or a TTL; the app's 60 s TTL stance is
adopted — stale-by-60s is acceptable because cron drives). Not an optimization: without
it every audited write enqueues a job. Waiting tokens are *not* indexed — they're
queried per matching event (bounded by waiting count, partial index in §4.4).

### 5.3 Correlator — the funnel, and the catch path

Per event, in the sweep's transaction:

1. **Index check** — nobody listening? done, no rows.
2. **Context** — `EventSource.context/1` → `to_feel_value` at the boundary (S-4).
3. **Match** — definition-level subscriptions on (kind, resource, action).
4. **Guard** — sandboxed FEEL; `nil`/error ⇒ `:guard_null`/`:guard_error` rows (S-3);
   outcomes recorded distinctly.
5. **Route** — `:static` or DMN through `DecisionResolver`; `:no_process` ⇒ no row
   beyond the ledger's `:skipped`.
6. **Instantiate** — resolve definition via the host's loader (baselines stay
   app-level, D1), `start_instance!(subject:, tenant:, correlation_id:, depth: d+1)`;
   dispatch row written transactionally with the start (G-1).
7. **Catch delivery** — for events whose (resource, action) signature appears among
   *waiting* tokens (partial index): compute the event-side key with each candidate
   subscription's `correlation_key_feel`; equal-and-non-null ⇒ `token.claim_waiting` →
   enqueue AdvanceWorker with the event's promotables; ledger row per delivery. First
   delivery wins the claim; siblings on the same node are killed (event-based-gateway
   behaviour falls out).
8. **Signals** — `kind: :signal` subscriptions matched by `signal_name`; broadcast to
   all, none consumed (FR-6.1).

Lookback: on park (§6), if `lookback_minutes > 0`, the parking transaction records the
watermark; the next sweep re-scans `occurred_at >= watermark` for that signature. The
log is the buffer; a lookup implements the TTL (FR-5.7).

**As built (2026-09-07, ash_bpmn PR #8).** The batch diagram above showed one
transaction under the lock; as built there is **one transaction per event, each holding
the per-tenant lock**, and the cursor advances in its own locked transaction after the
batch — prototype parity, so one bad event never aborts the batch, and the dispatch
identity remains the real arbiter. Guard `false` records no row; `nil` ⇒ `:guard_null`
(`:skipped`), error ⇒ `:guard_error` (`:failed`). `:no_rule_fired` is `:skipped` (TRD
over the prototype's `:failed`). A fresh cursor reaches high-water by one paged
`stream/3` walk — the behaviour has no latest-sequence callback (a future candidate).
Ledger values come from the raw adapter context while FEEL sees the `to_feel_value`'d
context. `:decision_error` also carries failed starts and unresolvable subjects with
the verbatim message in logs — the Dispatch resource has no detail column (a future
candidate). The index is host-started (the library owns no supervision tree) with
`reload!/0` for prompt invalidation and the TTL as backstop; the nudge's log-row field
names are configurable to the host's spelling.

## 6. Interpreter: the waiting state

- **Park**: entering a message/signal/conditional catch node stops token advance — no
  AdvanceWorker job — and writes the waiting fields: signature, key (FEEL over subject
  context, evaluated once here, S-5), lookback watermark, `parked_at`. A `:parked`
  process event records entry (diagnostics: how long, how often).
- **Wake**: the correlator's `claim_waiting` → AdvanceWorker advance (the normal loop —
  gateway evaluation, promotions, next node). Redelivery races die at the claim (G-4).
- **Cancel**: instance cancel, branch prune, boundary interrupt, and terminate all kill
  waiting tokens; parked TimerJobs (`:catch` kind) cancelled with them.
- **Boundary (route-only, D5)**: errors raised by `ash:call`/invoker retries exhaust
  `max_attempts` → the failure carries `(error_class, code)`; a boundary attached to the
  node's scope with a matching catch — class atom by default, optional `errorCode`
  equality — routes to its outgoing flow. Non-matching error propagates: instance
  `:failed`, as today. The boundary never re-enqueues (NG-6).
- **Terminate**: kills sibling tokens via the existing kill action; open tasks and
  timers cancelled through the same path as `cancel_instance!`.
- **Conditions and expiry**: every transition out of a node — completion, expiry,
  boundary — evaluates through one gateway routine in the interpreter; the facade's
  duplicate routing and its first-flow expiry bug are deleted (hygiene #3/#4/#5).

**As built (2026-09-17, `ash_bpmn` 8cda10b, 5cbce17, a057508).**

*Park* applies to **user tasks** as well as catch nodes, which the list above does not say.
It was the first thing built, because `{:park_token, true}` was a no-op: a token handed to
a human sat at `:executing` for however long the approval took, which is also the state of
a token whose job is running and of one whose job is lost. Nothing downstream could tell an
open approval from a crashed worker. A user task parks with **no** signature and **no**
correlation key — it is woken by someone completing that task, which names the token by id
— and leaving both nil is what keeps it out of the correlator's query rather than something
that has to be excluded from it.

*Wake* replaced two read-only `token.status == :executing` checks, on task completion and on
timer expiry. A status read says the token looked advanceable a moment ago and nothing about
whether anyone else is advancing it, so two deliveries of one completion both passed it.
Both now go through `claim_waiting`, which re-reads inside the transaction and admits one
winner. This is what makes catch delivery redelivery-safe without a lock.

*Entry* is recorded as `:node_entered` carrying `waiting_for` and the duration, not as a new
`:parked` kind. A parked token is a node the token entered and has not left; a second kind
for it would have to be kept consistent with the first.

*Terminate* is built, as a distinct effect rather than a flag on `complete_instance`. The
killing is not a detail of completing: it touches rows the terminating token knows nothing
about. One `:instance_terminated` event names the terminating node and the branches it took
down, rather than one row per killed token — the tokens already carry `:dead`. The open
`HumanTask` row is **not** retracted: someone was asked to approve something and the request
was withdrawn before they answered, and "there is no record of ever having asked you" is the
wrong answer.

*Timer catch events* are built and are the first wait that is not a person. Oban does all of
the waiting — `Oban.Stager` holds the job until `scheduled_at` and never promotes early — so
the worker is left with the part Oban has no opinion about: claim the token out of
`:waiting`, and if that loses (cancelled, terminated, or a redelivery of a job that already
ran) the wake is simply over. Losing is the normal ending, not an error.

*Boundary events and error boundaries* are **not** built. The bullets above describing them
remain a design, not a record.

### 6.1 Phase 3 as shipped, and where it departs from this document

Phase 3 is complete as of `ash_bpmn` e52e826: 563 tests, the exit criterion's three named
cases written and passing, and two of those three found real defects when written (expiry
took the first outgoing flow rather than evaluating conditions, so in a fixture where the
approved flow sorts first it granted the request it was meant to withdraw; and cancelling an
instance left its parked tokens alive, so a later event resumed a process nobody was running).

Four places where the built thing differs from the design above. Each is a refusal, and each
is recorded because a design document that quietly describes something else is worse than one
that is out of date.

**Error boundary events are refused, not built.** D5 specifies route-only error boundaries
catching an error class. `ActionInvoker.invoke/2` returns `{:error, term()}` with no error
code, so nothing distinguishes a modelled business error from Postgres being unreachable, and
a catch would route a transient outage down the declined branch -- ending the process having
decided something nobody decided. Error *end* events are built, with a distinct `:errored`
instance status so "the integration is down" and "the answer was no" stay different findings.

**`ash:timer kind="expire"` is not promoted to a boundary event.** It cannot be done
wholesale: `RequireApproval` schedules expire timers for standalone approvals, which have no
process instance and no graph to attach a boundary to. Where a graph does exist the rewrite
would change routing silently, because expire leaves down the task's own flow with
`outcome: :expired` for a following gateway to read and a boundary leaves down its own flow
with no outcome. The two are made mutually exclusive on a user task instead.

**Boundary events attach to user tasks only.** A service task's token is `:executing` inside a
running Oban job; Oban cannot interrupt a running job and a committed Ash action cannot be
un-run, which is compensation. Interrupting one would mean killing the token while the work
carried on.

**`lookback` is bounded by rows, not only by time.** The scan starts from the tenant's cursor
less a fixed number of events, because the event source reads forward from a sequence and
there is no way to seek by timestamp. A tenant busy enough to write more than that inside its
own window will not reach all of it.


## 7. Compiler and snapshot

- **Parsing**: `intermediateCatchEvent`, `boundaryEvent`, `terminateEvent`, event
  definitions on start/end events, and `ash:subscribe`/`ash:call` vocabularies join the
  moddle descriptor and the XML collector; the refusal walk normalizes prefixes and
  descends into children of supported nodes (FR-1.1/1.2).
- **Snapshot additions** (`Definition.graph`): node configs for catch nodes (kind,
  subscription descriptor, `correlation_key_feel`, `lookback_minutes`), boundary
  attachments (owner node, catch spec, interrupting flag), terminate ends, `ash:call`
  bindings (ref + inputs + promotes), `ash:load` lists, and the `boxic_feel` version
  stamp (FR-1.4). All expressions stored as source text, never ASTs (S-3/TRD §8).

  **As built (2026-09-07, `ash:call`).** The call binding stores `"call" => %{"ref" => …}`
  with `inputs`/`promotes` at *node level* — mirroring the decision config, so both
  service-task bindings share one runtime shape instead of forking it; the nested
  `%{ref, inputs, promote}` form this section originally sketched is **not** what
  ships. `ash:call` binds on `sendTask` too (the compiler treats it as the same node
  kind). One gap recorded for the follow-up lanes: a callable bound to a `read` action
  resolves at publish but fails at runtime with "not invocable" — it should be a
  publish-time refusal; and update/destroy callables build a bare-resource changeset,
  so hosts should prefer generic/create callables (documented in the interpreter
  moduledoc).
- **Verification** (`verify.ex`): callable refs exist (via domain introspection);
  `ash:subscribe` match resources audited + cycle-checked (via `EventSource`);
  decision refs exist (existing mechanism); guards/keys parse and lint boolean-ness;
  boundary targets are nodes in-graph; error codes referenced by boundaries exist on
  the guarded node's error vocabulary.

## 8. Expression engine

`AshBpmn.Feel` gains: the parse cache it deliberately lacks today (keyed by source hash
+ engine version, `:persistent_term`, write-once, capped — the `AshDecisions.Feel`
design, transplanted); `evaluate_guard/3` returning `{:ok, true | false | :null} |
{:error, t}` so null-vs-error is a value, not a lost distinction; the path-extraction
walk (`referenced_paths/1` — identifiers and path nodes, binding-aware for
`for`/quantifiers) for index building and diagnostics. Sandbox posture unchanged:
kill-timeout per evaluation for tenant-authored sources; the worker-pool option is the
answer if spawn cost bites at stream throughput (OR-4 measures it first).

## 9. Designer

Panel additions in dependency order: condition editor (validate-on-edit), `businessRuleTask`
forms, `ash:call` dropdown + argument rows, start-event subscription authoring
(resource/action pickers from `EventSource.audited?` + guard field), catch/boundary
config (kind, key expression, lookback), signal palette. The moddle descriptor grows
the matching vocabularies; `apply_config` keeps its rebuild-preserving behaviour. No
generic bpmn-js properties panel — server-rendered forms stay the pattern.

## 10. Replacement, not migration (D1)

> **Note, 2026-09-07.** An earlier revision of this section specified an
> absorption-and-cutover sequence — dual-run with shadow dispatches, one-deploy data
> migration, sweep-lock coordination. It assumed a production system to protect. There
> is none: the app's `Process` domain has never run outside development. The machinery
> is deleted from this design. The library lands, the app modules are deleted in the
> same change, and no data migrates. The prototype existed to prove the patterns; it
> has; it retires.

The prototype's modules map to their successors as the implementation checklist:

| App module (prototype) | Becomes |
|---|---|
| `Process.Trigger` | `AshBpmn.Resources.Subscription` |
| `Process.TriggerCursor` | `AshBpmn.Resources.Cursor` |
| `Process.TriggerDispatch` | `AshBpmn.Resources.Dispatch` |
| `Process.Triggers.{Notifier,CronSweep,SweepWorker,Index}` | `AshBpmn.Triggers.*` |
| `Process.Triggers.Dispatch` (funnel) | `AshBpmn.Triggers.Correlator` |
| `Process.{Binding,Resolver}`, baselines, `priv/bpmn` publishing | **stays app-level**, feeding the engine resolved definitions |
| `Process.Domain` | deleted when the library lands; `config :ash_bpmn, event_source: AshEnterprise.Audit.EventSource` |

One sweep implementation ever runs against a tenant — there is no lock-name handoff to
coordinate, and development databases re-seed rather than migrate.

**As built (2026-09-07, ash_enterprise PR #5).** The adoption is complete and the gate
green (274/274 + a dev smoke: seed → setup → 4/4 dispatches `:started`, one instance
completed). The honest findings, stated where they live: **subscriptions resolve
`latest_published` in-tenant — cross-tenant baseline divergence is a documented gap
pending a loader seam** (Process's moduledoc; `bpmn.setup` publishes a local copy per
seeded tenant so the demo runs while the gap stands). The crontab entry is spelled
literally in `config.exs` because a function call there breaks a cold `mix setup`
(config evaluates before deps compile). With `:base` owning tenancy, the host declares
Cursor's one-per-tenant identity itself, and the app-domain cycle refusal
(`Bpmn.`/`Decisions.`/`Process.` prefixes) is restated as a host validation — the
library refuses only its own domains. The index rebuilds synchronously **after commit**
on every subscription lifecycle act (an in-transaction rebuild reads the pre-commit
snapshot and misses the row that caused it), skipped when the index isn't running. The
adapter isolates the NULL-tenant chain explicitly — the log's `global? true` tenancy
would otherwise stream every tenant as one chain, the global cursor this design
refuses.

## 11. Testing

- The Oban inline shim (`config :ash_bpmn, oban_testing: :inline`) extends to the
  sweep: dispatches execute synchronously; timer jobs stored and fired explicitly via
  `TestJobs.fire!/2` — never `Process.sleep`.
- The negative paths are the suite: guard null/error, decision error vs no-rule,
  no-definition, disabled-not-retroactive, claim races, stale redelivery,
  late-event-after-cancel, expiry-honors-default, boundary-route-no-retry,
  terminate-siblings, cycle refusals, depth bound, lookback 0 vs N, best-effort chains
  dispatching without ordering promises.
- A corpus test drives bpmn-js-authored XML (real-world shapes, both prefixes) at the
  compiler for FR-1.x.
- Property tests: nil/type_error ⇒ no-match across generated guards; correlation
  freeze under subject mutation; replay determinism (dispatch a tenant's whole log
  twice → identical instance sets, by ledger identity).

## 12. Performance notes and honest ceilings

- One sweeper per tenant is a throughput ceiling (the app measured it as real and
  unmeasured; the library keeps the statement). Batching is 500; lag telemetry makes
  the ceiling visible (OR-1/OR-4).
- Sandbox spawns one process per guard evaluation. Pool before you drop the sandbox;
  measure before you pool.
- The ETS index keeps the common case (nobody listening) at one lookup per event.
- Waiting-token correlation is one indexed query per event that has candidates.
- Signals broadcast to all matching subscriptions by design — a wide signal on a busy
  tenant is a fan-out; the ledger's `max_starts_per_event` bounds the start side, and
  signal catch counts are visible in telemetry.

## 13. Risks

| Risk | Mitigation |
|---|---|
| The ordering guarantee is ash_events' implementation detail | Adapter declares it; moduledoc pointer; CI probe candidate (plan §10.1) stays on the books |
| Designer authoring of subscriptions creates bad guards at scale | Validate-on-edit + `:guard_null`/`:guard_error` ledger rows make mistakes visible per-event |
| Event vocabulary sprawl (each new event definition = compiler surface) | The FR-1.1 refusal posture: anything unparsed is an error, so vocabulary grows deliberately |
| Facade/interpreter routing divergence recurs | One gateway routine (§6); the facade's copy is deleted, and a test fails if `complete_task!` and the interpreter disagree on a shared corpus |
