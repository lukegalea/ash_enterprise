# ADR 0030 — Events trigger processes through a dispatched cursor, not a handler

- **Status:** accepted
- **Date:** 2026-08-20

## Context

A process that starts because a developer put `AshBpmn.Changes.RequireApproval` on an action is a
process the *code* decided to start. The claim this repository markets is the other one: something
happened, so a process began — configurable, versioned, and answerable to "why did this start?"

The obvious implementation is a handler. `ash_events` has no handler mechanism here, so the shape
would be: subscribe to the audit log, and mark each event dispatched as you go.

**That is impossible, and the impossibility is the whole design.** Per
[ADR 0020](0020-tamper-evident-audit-log.md), `audit_events` carries a `BEFORE UPDATE OR DELETE`
trigger that raises. **An event cannot be marked.** There is no per-row state to reconcile against,
so the usual at-least-once-plus-idempotency arrangement has nowhere to keep its bookkeeping.

What is left is a cursor: a high-water mark on `sequence`, walked forward. A `bigserial` is the
canonical wrong thing to build a change feed on — values are assigned at `INSERT`, so two
transactions can take 100 and 101 and commit in the other order, and a consumer holding a high-water
mark loses 100 permanently and silently, with no gap it can detect because sequences also gap on
rollback.

**It is nonetheless safe here, per tenant, and that was measured rather than assumed.** `ash_events`
takes a `pg_advisory_xact_lock` keyed on the tenant *inside* the audited action's transaction and
*before* inserting the event row. Three probes, run against the dev database on 2026-08-19 and
recorded in `docs/plans/event-triggered-processes.md`:

* **The lock is transaction-scoped and releases at `COMMIT`.** Two connections on the same key, the
  first holding 1500 ms: the second's acquire returned `db=1500.3ms` and landed 0 ms after the
  first's commit point. So a second transaction for the same tenant cannot consume `nextval()` until
  the first has committed — **within one tenant, `sequence` order is commit order.**
* **There is an enclosing transaction**, which is not obvious given `AshEnterprise.Repo` sets
  `prefer_transaction? false`. An audited create traces as
  `begin / INSERT <resource> / pg_advisory_xact_lock / INSERT audit_events / commit`.
* **The one-argument and two-argument advisory locks are separate lock spaces.** The default key
  generator returns a two-element list under attribute multitenancy and a single integer otherwise.
  Holding `(0, 0)`, a `(0)` acquires in about a millisecond. So the `NULL`-tenant chain has **no**
  ordering guarantee, not a weaker one.

That guarantee is `ash_events`' implementation detail, not this schema's. A custom
`advisory_lock_key_generator`, or an upstream change to when the lock is taken, invalidates all of
it — and would do so silently, because the failure is a consumer skipping an event rather than an
error. Which is why the note now lives in `AshEnterprise.Audit.EventLog`, where the property is
produced, rather than only in the consumer that depends on it.

## Decision

**Dispatch is a cursor walked by a scheduled sweep. The audit notifier is a debounced nudge and
nothing more.**

The instinct is the reverse — the notifier looks like the driver and the cron looks like a
belt-and-braces backstop. It is exactly backwards. An unmarkable stream has no per-row state to
reconcile against, so two writers advancing it is a race with no arbiter; one driver walking a cursor
per tenant is trivially correct. And the notifier *cannot* be the driver: Ash defers notifications
past the transaction, so enqueuing from one is not transactional with the write, and a crash between
`COMMIT` and `Oban.insert/2` loses the nudge silently and undetectably. **Losing a nudge must cost
latency, not correctness.** `AshEnterprise.Process.Triggers.Notifier` says so in those words, because
anyone who removes the cron and relies on it gives the system a silent failure mode.

Six commitments follow.

**1. An ETS index keeps the cost off everything else.** `AshEnterprise.Process.Triggers.Index` holds
the set of resource names any published trigger watches. Without it, the notifier on the audit log
would enqueue a sweep for **every audited write in the application** — a cost imposed on the whole
system for a feature most tenants will not use. With it, the overwhelmingly common case is one
`:ets.member/2` that finds nothing and returns. The index is rebuilt on a 60-second TTL and on
notification, so a newly published trigger can be invisible to the *notifier* for up to a minute;
that is acceptable only because the sweep reaches those events anyway.

**2. Three stages, ordered by cost.** Stages one and two run against every audited write on a
matched resource:

| Stage | What it is | Cost |
|---|---|---|
| **Match** | structural comparison on resource, action, action type | O(1), no evaluation |
| **Guard** | a FEEL boolean over the event context — *"only requests over five thousand"* | in-process, no I/O |
| **Route** | a DMN decision naming the process key and its variables | a read and an evaluation, reached only by matched-and-guarded events |

A guard that cannot answer is not a guard that says yes: FEEL folds a missing path or a type
mismatch to `null`, and `null` is treated as false, because treating it as "fire" would start
processes from conditions nobody wrote.

**3. `TriggerDispatch` is the ledger, and its second job is the valuable one.** One row per
`(trigger_id, event_id)`, written in the same transaction as the instance start. The cursor already
makes duplicates impossible in the ordinary case; the identity makes them impossible under partial
failure. But the reason it exists is that it answers **"why did this process start?"** — the first
question anyone asks when a process appears that nobody remembers requesting, and the one nothing
else in the system can answer. It records the trigger and its version, the event and its sequence,
the decision and the rule that fired, and the instance that resulted. It is the trigger layer's
`Process.Event`: it records what the audit log structurally cannot, and it never duplicates a row
change.

**4. `enabled` is mutable; `status` and `version` are not.** Retiring a version is a deployment act.
Switching a misfiring trigger off at two in the morning is an operational one, and conflating them
means the only way to stop a bad trigger is to publish a new version of it. **Disabling is not
retroactive** — events already behind the cursor still fire when the sweep reaches them. That is the
opposite of what everyone assumes, so the moduledoc states it rather than leaving it to be
discovered.

**5. A broken trigger must never wedge the audit stream.** The cursor advances past events it could
not dispatch, and the failure is recorded as data with a reason: `:guard_false`, `:guard_error`,
`:decision_error`, `:no_rule_fired`, `:no_published_definition`, `:fan_out_exceeded`,
`:already_dispatched`, `:self_trigger_refused`. `:decision_error` and `:no_rule_fired` are separate
values on purpose — a decision that raised is a bug and a decision that matched nothing is a
modelling gap, and one log entry covering both is a log entry nobody can act on. A `COLLECT` routing
decision returning more targets than `max_starts_per_event` fails loudly rather than starting fifty
thousand processes from one write.

**6. Two refusals at publish time, both for silent-never-fires.** A trigger may not match a resource
in the `AshEnterprise.Bpmn.`, `AshEnterprise.Decisions.` or `AshEnterprise.Process.` namespaces:
those audit their own writes, so a process started by a trigger produces trigger inputs and a trigger
matching one would feed itself. Refused by module *prefix*, so a resource added to one of those
domains later is covered without anyone remembering to come back; `TriggerDispatch.depth` bounds any
indirect path, because "probably terminates" is not a standard this repository accepts.

And a trigger may not match a resource that is not audited, because **the audit log is not a change
feed.** It is a feed of writes that went through an Ash action. `ash_events` appends by *wrapping
actions*, not by observing changes, so anything that changes a row without running one produces no
event. The case that will actually bite is the strangler: `AshEnterprise.Legacy.User` reads a view
over `legacy.users` and the writes worth reacting to are the old application's raw SQL.
`AshStrangler.Listener` does synthesize an `Ash.Notifier.Notification` for them — that is what makes
the LiveView update live — but a notification is not an event, and nothing connects them. Measured:
`Ash.Resource.Info.notifiers(AshEnterprise.Security.Role) == []`, because `ash_events` registers
none. So *"a user appears in the legacy system, start onboarding"* — among the first things anyone
will try to model on a strangler-migrated application — would have waited forever with nothing to
show for it.

### The actor, and why it is not the requester

**An event-triggered process runs as `AshEnterprise.Platform.SystemActor.process()`, with the human
in `started_by_id` and the correlation id carried through.** Three reasons, in order of weight:

1. **A process outlives a session, and a session's authority must not outlive it.** Rebuilding the
   requester's `ActorContext` would hand the instance their grants for the whole life of the
   process — days or weeks — surviving a role change and surviving offboarding.
2. **The context is genuinely gone by sweep time.** Rebuilding it costs five queries and yields a
   *different* context from the one the request had, which is worse than not having it: it looks
   authentic and is not.
3. **The trail keeps the human anyway.** `started_by_id` is what an auditor reads to answer "whose
   request was this", and the system-actor name preserves the distinction
   `AshEnterprise.Audit.EventLog` already argues for — *"the nightly reconciliation did this"* and
   *"we failed to record who did this"* are different findings.

Authority and accountability are different columns. **Human decisions inside the process are still
attributed to the human**, because claiming and completing a task arrive on a real request with a
real actor.

### The event context is a published contract

The map a guard and a routing decision both see — `event`, `actor`, `tenant`, `data`, `changed`,
`metadata` — is documented and tested as a contract, because changing it breaks every tenant's
triggers. One trap named in it: **`data` is the event's snapshot, not a live read.** By sweep time
the record may have changed or been archived. That is correct — a trigger fires on what happened —
but it means the process it starts must re-read its subject through Ash. Same rule as "tokens carry
routing, not business data", one layer up.

## Does it consume ActorContext?

**Partly, and the split is deliberate rather than an omission.**

Everything a person touches does. `Trigger`, `TriggerDispatch` and `Binding` are platform resources —
organization-owned, tenant-scoped, policy-governed — so who may publish a trigger or read the
dispatch ledger is a role grant like any other, and publishing one is audited.

The sweep does not, and cannot. It runs in an Oban worker long after the request that caused the
event, and it deliberately does **not** reconstruct the requester's context — that is the actor
decision above. It reads as a named system actor, which the policy set bypasses. So the honest
statement is: **the dispatcher's authority is the system actor's, and it is bounded by what a trigger
can be configured to do rather than by a per-request context.** What bounds it is the funnel's
narrowness — a trigger names a process key and a variable mapping, and the process it starts performs
every mutation through an ordinary Ash action with its own policies — not the dispatcher's own
credentials.

## Consequences

**What this makes easy.** A process that starts from a fact rather than from a wiring decision, with
a queryable answer to why. Latency that is a tuning parameter rather than a correctness property: the
nudge makes the common case sub-second and the cron makes the guarantee. And a per-tenant stall that
is a *detected* condition — `TriggerCursor.lag_seconds` plus a health check — rather than a support
ticket.

**What this makes hard.** Four things, and none of them is hypothetical:

- **Latency is bounded by the cron, not by the write.** The worst case for a tenant whose nudge was
  lost is a minute. For an approval workflow that is invisible; for anything a user is waiting on, it
  is not, and the honest answer is that this is not a synchronous mechanism and should not be made
  into one.
- **The `NULL`-tenant chain is best-effort and says so.** It gets its own cursor and no ordering
  guarantee at all. `Accounts.User` is `tenant?: false`, so *user* events are on that chain — which
  means the most obvious trigger anyone will want to write is the one with the weakest guarantee.
- **The guarantee is borrowed.** It rests on when `ash_events` takes its advisory lock. That is now
  written down where the property is produced, and it is still someone else's implementation detail.
- **Ordering across tenants means nothing.** There is one cursor per tenant and deliberately no
  global one, so a trigger cannot express "after X in tenant A and Y in tenant B", and nothing in
  the API hints that it might.

**What was found by running it, not by reasoning about it.** Two of the design's original decisions
were wrong and the failures were silent:

- **One transaction around the whole sweep.** A Postgres error *aborts* the transaction, so catching
  the exception changed nothing: one event whose process could not start took the entire batch with
  it — the other events' dispatches, their instances and the cursor advance — leaving no record of
  having tried. Restructured to **one transaction per event**, with `TriggerDispatch`'s
  `[:trigger_id, :event_id]` identity as the arbiter across concurrent sweeps rather than a lock.
  Found by a service task raising and an entire sweep vanishing, instance included.
- **A cursor starting at zero.** Obvious, and badly wrong: the sweep would walk a tenant's entire
  history and start a process for every historical event that matched. On a tenant with a real audit
  trail that is thousands of processes for things that happened months ago, and the first symptom is
  the queue rather than the mistake. A cursor now begins at the tenant's current high-water mark, and
  is created when a trigger is **published** as well as by the sweep — otherwise everything between
  publishing and the first sweep would fall in the gap.

**And one that was caught by a test rather than by review.** A resource name has three spellings: the
`audit_events` column holds `"Elixir.AshEnterprise.Security.Role"`, Ash casts it back to a module
*atom* on read, and a person types `"AshEnterprise.Security.Role"`. The first implementation compared
a stored string against the atom, so every trigger would have matched nothing — the same silent
never-fires the validations above exist to prevent, arriving through the back door. Settled on the
short form, because it is what a person types and what a FEEL guard compares against:
`event.resource = "AshEnterprise.Accounts.User"` reads like the thing it means.
`Trigger.ResourceName` is the single place that knows, and the test asserts against a real audited
write rather than against a remembered format — asserting the raw field is what would have hidden it.

**What it forecloses.** Exactly-once dispatch, and any design that needs it. The cursor plus the
dispatch identity give at-most-once *per (trigger, event)* with a recorded reason for everything that
did not happen, which is a different and weaker promise than a transactional outbox would give. An
outbox was considered and is not needed given the ordering guarantee; adopting one later means adding
a table the audit log's immutability trigger does not cover, which is a new write path to secure.

## Reversal

**To turn dispatch off without removing it:** `Trigger.set_enabled(false)` on every published
trigger, or drop the cron entry. Nothing starts, cursors stop advancing, and the dispatch ledger
stays queryable. Minutes, and fully reversible — but note that re-enabling replays everything behind
the cursor, which is the disabling-is-not-retroactive rule read backwards.

**To remove the mechanism:** delete `lib/ash_enterprise/process/trigger.ex`, `trigger_cursor.ex`,
`trigger_dispatch.ex` and `lib/ash_enterprise/process/triggers/`, remove
`AshEnterprise.Process.Triggers.Notifier` from `AshEnterprise.Audit.EventLog`'s `notifiers`, drop the
cron entry and the `:bpmn` queue's sweep jobs, and generate a migration dropping
`process_triggers`, `process_trigger_cursors` and `process_trigger_dispatches`. Roughly a day. The
audit log is untouched — it never knew it was being read, which is the property that makes this
reversible at all.

**What does not reverse** is the ordering note in `AshEnterprise.Audit.EventLog`. It should stay
whether or not this consumer does: the hash chain still piggybacks on that lock, and a dependency on
someone else's implementation detail written down only in the consumer is a dependency that breaks
quietly.
