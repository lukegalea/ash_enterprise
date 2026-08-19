# Plan — Event-triggered processes, and per-tenant process configuration

> **Status: specified, not built.** Written after `ash_bpmn` and `ash_decisions` were adopted
> (commit `8ba5a3d`) and before any of the below exists. Where it states a fact about Postgres
> or about a dependency, that fact was measured on this machine and the measurement is
> included — because the load-bearing claim in §2 is one that is true by accident of an
> upstream implementation detail, and a plan that merely asserted it would be a plan that
> breaks silently when the detail changes.

## Why this document exists

Two capabilities are wanted, and they share one hard problem.

**Workflows should start from things that happen**, not only from someone pressing a button.
A request is submitted, a contract approaches expiry, a vendor's insurance lapses — and a
process begins, without a developer having wired that particular button to that particular
process.

**A tenant should be able to change how a process behaves** without a deploy and without
forking the platform's copy of it permanently.

The shared problem is that both make **process configuration into data**, and data that
decides what the system does needs the same treatment as data that records what it did:
versioned, tenant-scoped, authorized, and auditable. Neither is a scheduling problem.

---

## 1. What already exists, and what is missing

`ash_bpmn` and `ash_decisions` are adopted. Their tables are this application's, their
resources sit on `AshEnterprise.Platform.Resource`, and the engines' authority is the first
bypass in the base's policy set (see `test/ash_enterprise/bpmn/adoption_test.exs`). A process
can be started by calling `AshBpmn.start_instance/2`.

What does not exist:

| Missing | Consequence today |
|---|---|
| Anything that watches the audit log | A process starts only when application code calls the facade |
| A notion of a platform baseline | Every tenant would have to author every process itself |
| A way for a tenant to diverge from a baseline and be told it has | Improving a shipped process reaches nobody |

`ash_events` has **no handler or subscriber mechanism at all** — it persists events and stops.
So there is nothing to subscribe to; the dispatch has to be built.

---

## 2. The ordering guarantee, and exactly how far it reaches

Everything in §3 rests on one property, so it was measured rather than assumed.

### The hazard that does not apply here

A `bigserial` is the canonical wrong thing to build a change feed on. Values are assigned at
`INSERT`, not at `COMMIT`, so two concurrent transactions can take 100 and 101 and commit in
the opposite order. A consumer holding a high-water mark advances past 101, and 100 commits
afterwards and is never seen. Silently: sequences also gap on rollback, so a missing number
proves nothing.

`AshEnterprise.Audit.EventLog.sequence` is exactly such a column.

### Why it is nonetheless safe, per tenant

`AshEvents` takes a **per-tenant `pg_advisory_xact_lock` immediately before inserting the
event row**, inside the audited action's own transaction
(`deps/ash_events/lib/events/action_wrapper_helpers.ex:48-61`). `xact` scope means it is held
until `COMMIT`. A second transaction for the same tenant therefore cannot reach its `INSERT`,
and so cannot consume `nextval()`, until the first has committed.

**Within one tenant, sequence order is commit order.** The reordering hazard cannot occur.

Three things were checked rather than reasoned about, because two of them are the kind of
detail that quietly stops being true:

1. **The lock serializes and is released only at `COMMIT`.** Two connections, same key, first
   holding for 1500 ms: the second's `pg_advisory_xact_lock` returned `db=1500.3ms` and
   acquired 0 ms after the first reached its commit point. A session-scoped or early-released
   lock would have let it through immediately.
2. **There is an enclosing transaction.** This matters because `AshEnterprise.Repo` sets
   `prefer_transaction? false`, and outside a transaction every statement is its own — the
   lock would be released before the `INSERT` that consumes the sequence, and "the lock
   precedes the insert" would prove nothing. Instrumenting `[:ash_enterprise, :repo, :query]`
   over one audited create gives:

   ```
   begin
   INSERT INTO "roles"
   SELECT pg_advisory_xact_lock($1, $2)
   INSERT INTO "audit_events"
   commit
   ```

3. **The `tenant?: false` chain gets no guarantee at all** — and for a sharper reason than
   "it is a different chain". `AshEvents.AdvisoryLockKeyGenerator.Default` returns a
   **two-element list** for attribute multitenancy and a **single integer** otherwise, so the
   two paths call `pg_advisory_xact_lock($1, $2)` and `pg_advisory_xact_lock($1)`
   respectively. Postgres treats those as **separate lock spaces**: holding `(0, 0)` in one
   transaction, `(0)` in another acquired in **1 ms**. There is no mutual exclusion between
   the chains whatsoever.

### The consequences, which belong in the code and not only here

- The design is **per tenant**. One cursor per tenant, never a global one.
- The `organization_id IS NULL` chain — which is where `Accounts.User`'s events land, since
  `User` is `tenant?: false` — gets **its own cursor and is best-effort**. It is not merely
  weaker; it has no ordering guarantee to weaken.
- The guarantee is a property of **`ash_events`' implementation**, not of our schema. A note
  goes in `AshEnterprise.Audit.EventLog` beside the existing advisory-lock paragraph saying
  so, because a consumer that silently depends on an upstream detail is a consumer that
  breaks silently when it changes.
- Configuring a custom `advisory_lock_key_generator` invalidates all of it.

---

## 3. Dispatch: the sweep is the driver, the notifier is a nudge

The instinct is a notifier fast path with a sweep as safety net, mirroring `ash_bpmn`'s own
"the job is the driver, the reconciliation sweep is the net". **Invert it here.** The audit
table cannot be marked — a Postgres trigger raises on `UPDATE` and `DELETE` — so there is no
per-row state to reconcile against, and two writers advancing an unmarkable stream is a race
with no arbiter. One writer, holding a lock, walking a cursor, is trivially correct.

```
audited write ──▶ audit_events row (sequence N, tenant T)
                        │ Ash.Notifier → ETS trigger index on {resource, action_type}
                        ▼ (hit only)
        Oban.insert(SweepWorker, %{tenant: T}, unique: [period: 5, keys: [:tenant]])
                        │
   Oban cron (60s) ─────┘
                        ▼
   SweepWorker: pg_advisory_xact_lock(:trigger_sweep, T)
                read cursor → events (sequence > last, asc, limit 500)
                match → guard (FEEL) → route (DMN) → start
                write TriggerDispatch rows + advance cursor, one transaction
```

**The notifier is only a nudge, and it must be**, for a reason that is the opposite of the one
first supposed. Ash defers notifications until the transaction is over
(`deps/ash/lib/ash/notifier/notifier.ex:180`: *"A notification can only be sent if you are not
currently in a transaction"*), so a notifier does **not** run inside the advisory lock and does
not extend it. But that also means **enqueuing from a notifier is not transactional with the
write**: a crash between `COMMIT` and `Oban.insert` loses the nudge silently. Losing a nudge
must therefore cost latency and not correctness — which it does, because the cron sweep will
reach the same events regardless.

A transactional outbox solves the same problem and was considered. It is not needed given §2:
the cursor already makes "did this event get processed" answerable, and an outbox would add a
second table to keep drained.

**The ETS index is not an optimisation.** Without it, every audited write in the application
enqueues a job — a cost imposed on the whole system for a feature most tenants will not use.
It is built from published triggers, invalidated by `Ash.Notifier.PubSub` plus a 60 s TTL;
stale-by-60 s is acceptable precisely because the cron sweep is the driver.

---

## 4. The resources

### `AshEnterprise.Process.TriggerCursor`

One row per tenant. `last_sequence`, `last_dispatched_at`, and a `lag_seconds` calculation.
`identity :one_per_tenant, []`, which under attribute multitenancy becomes a unique index on
`organization_id` alone.

`ownership: :none`, `lifecycle?: false`, `audit?: false` — auditing a cursor is noise.

### `AshEnterprise.Process.TriggerDispatch`

One row per `(trigger_id, event_id)`, written **in the same transaction as the instance
start**. `status` (`:started | :skipped | :failed`), `reason`, `decision_key`, `fired_rule`,
`process_key`, `instance_id`, `event_sequence`, `correlation_id`.

Deliberately belt-and-braces: the cursor alone makes duplicates impossible, and the identity
makes them *provably* impossible under a partial failure. The more valuable half is that it
answers **"why did this process start?"**, which is the question an auditor actually asks. It
is the trigger layer's `ProcessEvent`: it records what the audit log structurally cannot, and
never duplicates a row change.

### `AshEnterprise.Process.Trigger`

Versioned and immutable-on-publish, copying `AshBpmn.Resources.Definition`'s discipline —
a trigger is as much a deployed artifact as a process is.

| Attribute | Purpose |
|---|---|
| `key`, `version`, `status` | `:draft \| :published \| :retired`; publish is one-way |
| `match_resource` | The coarse, indexed key |
| `match_action`, `match_action_type` | Nullable = any |
| `guard_feel`, `guard_ast` | A FEEL boolean, compiled at publish |
| `decision_key` | The DMN decision that routes; nullable |
| `process_key` | Static fallback when `decision_key` is null |
| `variable_mapping` | Process-variable name → FEEL expression |
| `enabled` | Operational switch, separate from `status` |
| `max_starts_per_event` | Default 1; bounds a `COLLECT` fan-out |

`enabled` is mutable while `status` and `version` are not. Retiring a version is a deployment
act; switching a misfiring trigger off at 2am is an operational one, and conflating them means
the only way to stop a bad trigger is to publish. **Disabling is not retroactive**: events
already behind the cursor still fire when the sweep reaches them. That is the opposite of what
everyone assumes and belongs in the moduledoc.

---

## 5. The three-stage funnel

1. **Match** — structural comparison on `{match_resource, match_action, match_action_type}`.
   O(1), ETS, no evaluation.
2. **Guard** — a FEEL boolean over the event context. In-process, no I/O. Where "only requests
   over £5,000" lives.
3. **Route** — a DMN decision through `AshEnterprise.Decisions`, returning the process key and
   variables, plus which rule fired.

The split matters because stages 1 and 2 run against *every* audited write in a matching
resource and stage 3 is the expensive one. It is also the DMN-idiomatic decomposition: the
guard is an expression, the routing is a decision table with a declared hit policy.

### The event context is a published contract

Both the guard and the decision see the same map. Changing its shape breaks every tenant's
triggers, so it is documented and tested as a contract:

```elixir
%{
  "event" => %{"id", "sequence", "occurred_at", "resource", "action",
               "action_type", "record_id", "version"},
  "actor" => %{"user_id", "system_actor", "impersonator_id"},
  "tenant" => %{"organization_id"},
  "data" => %{...},      # the record as written
  "changed" => %{...},
  "metadata" => %{...}   # correlation_id, depth
}
```

**`data` is the event's snapshot, not a live read.** By sweep time the record may have changed
or been archived. That is correct — a trigger fires on what happened, not on what is now true
— but it means a guard must never be written as if it were a query, and the process it starts
must re-read its subject through Ash. Same rule as *tokens carry routing, not business data*,
one layer up.

---

## 6. Actor, tenant, correlation

**An event-triggered process runs as `AshEnterprise.Platform.SystemActor.process()`**, with the
originating human recorded in `Instance.started_by_id` and in the correlation id.

Three reasons, in order of weight:

1. **A process outlives a session; a session's authority must not.** Rebuilding the requester's
   `ActorContext` and handing it to the engine would give the instance that person's grants for
   the instance's whole life — days, in an approval chain. Offboard them on Tuesday and
   Monday's process keeps acting with their reach. That is a standing privilege-escalation
   surface created by a convenience.
2. **The context is genuinely gone.** It is built per request by `LoadActorContext`; the sweep
   runs minutes later in a job with no request. Rebuilding it costs five queries and rebuilds a
   *different* context than the write happened under.
3. **The trail keeps the human anyway, and keeps the distinction.** `started_by_id` names them,
   the correlation id joins the whole thing back, and every engine write carries
   `system_actor: "process"` — which is exactly the distinction `event_log.ex` already argues
   for: *"the nightly reconciliation did this" and "we failed to record who did this" are
   different findings.*

**Human decisions inside the process are still the human's**, because claiming and completing a
task arrive on a real request with a real `ActorContext`. Two tests: an engine advance carries
the process actor; a task completion carries the person.

**Tenant** comes from the cursor, travels in the Oban args, and is passed as `:tenant` to
`start_instance/2`. **Correlation** travels event → dispatch row → job args →
`Correlation.with_correlation/2` around the worker → `start_instance(correlation_id:)`.

---

## 7. The invariant that stops it eating itself

Some BPMN and decision resources **carry the audit hook** — `Definition` and `HumanTask` do,
because publishing a process and deciding a task are governance events. So a process started
by a trigger writes an audit event, which is a trigger input.

**A trigger may not match a resource in `AshEnterprise.Bpmn` or `AshEnterprise.Decisions`.**
Refused at publish time with the resource named. Plus a `depth` marker carried in the dispatch
metadata and bounded, so a cycle through some future indirect path is *bounded* rather than
merely improbable.

This was very nearly left to the resource filter, which existed for cost rather than for
cycles. "Probably terminates once the trigger is filtered" is not a standard this repository
accepts, and the unbounded version would have been discovered in production.

---

## 8. Platform baselines and per-tenant bindings

### The grit

`:base` + `tenant?: true` raises by design, and the platform base makes `organization_id`
`allow_nil? false`. **A NULL-tenant baseline row is impossible.** Relaxing that would weaken
the tenancy invariant for every resource in the application to serve one; refuse it.

So: a real `Organization` row, `unique_name: "platform"`, seeded idempotently. No users, no
roles, no sign-in, excluded from tenant listings, and a test asserting all of that.

### What already works

Verified against `AshBpmn.Resources.Definition` and the AshPostgres migration generator:
`identity :unique_key_version, [:key, :version]` defaults to `all_tenants?: false`, and
`Operation.index_keys/3` prepends the multitenancy attribute — so the unique index is
`(organization_id, key, version)` and **per-tenant version sequences work unchanged**. The same
holds for the partial draft index. `AssignVersion` reads `max(version)` in the changeset's own
tenant, so two tenants' v1s are independent.

### `AshEnterprise.Process.Binding`

| Attribute | Purpose |
|---|---|
| `kind` | `:process \| :decision` — one table, identical lifecycle |
| `key`, `source` | `:platform \| :tenant` |
| `target_id`, `bound_version` | What this tenant runs |
| `forked_from_version` | The platform version diverged from — the basis of the drift report |
| `bound_at`, `bound_by_id` | Provenance |

`identity :one_per_key, [:kind, :key]`. `audit?: true` — rebinding a workflow is exactly what
an auditor should find in the log.

**The load-bearing default: no row means "follow the platform baseline, latest published."**
Absence is the default, so provisioning a tenant writes nothing, a newly published baseline is
live everywhere immediately, and reverting a customization is *deleting a row*. Any design
where the default is a row is one where onboarding means backfilling a row per workflow
forever.

### Resolution

`Resolver.resolve(kind, key, tenant)`: binding present and `:tenant` → that target; present and
`:platform` → the *pinned* platform target (a tenant may deliberately hold at v3 while v5
exists); absent → `latest_published(key)` in the platform tenant. Two indexed reads worst case,
called **once per instance start**, never per advance.

The cross-tenant read is the only one in the design and lives in one named function,
`Resolver.load_platform_definition/1` — not `tenant: nil` sprinkled through the engine. Safe on
three counts: it is by primary key or by `(platform_tenant, key, status)`; the target is
immutable; and definitions are not customer data.

This is what `AshBpmn.start_instance/2`'s `:definition` option and the
`AshBpmn.DefinitionLoader` seam were added for — both landed in `27a1a90`.

### Drift, and what we refuse to do about it

`Resolver.drift(tenant)` returns, per customized key,
`{forked_from_version, platform_latest, behind_by}`, rendered as *"customized · forked from
platform v3 · platform is now v5"*.

Deliberately **not** an automatic merge and **not** a diff. The two documents have diverged and
reconciling them is the round-tripping problem in another costume. "You are behind", plus a
side-by-side viewer, is honest; a merge is not.

**In-flight instances never migrate.** They pin `definition_id` at creation; rebinding changes
only what *new* instances resolve to. One explicit test rather than a paragraph: start an
instance, rebind, assert the running instance's `definition_id` is unchanged and its viewer
still renders the old XML with its tokens in the right places.

### Baselines are code, not UI

Publishing into the platform organization must be impossible from the web. Baselines live as
reviewed artifacts in `priv/bpmn/*.bpmn` and `priv/dmn/*.dmn`, published by
`mix ash_enterprise.bpmn.publish` running as a system actor — the same shape as
`priv/legacy/schema.sql` applied by `mix ash_enterprise.legacy.setup`.

---

## 9. Failure semantics

**A broken trigger must never wedge the audit stream.** The cursor advances past events it
could not dispatch and the failure is recorded as data.

| Failure | Behaviour |
|---|---|
| Guard raises or returns a non-boolean | `:failed`, `reason: :guard_error`; cursor advances. A guard that cannot decide is not a guard that says yes. |
| Decision errors vs no rule fires | Distinguished: `:decision_error` is a bug, `:no_rule_fired` is a modelling gap |
| No published definition for the key | `:failed`; surface `start_instance/2`'s message verbatim |
| Trigger disabled | Not matched, nothing recorded, not retroactive (§4) |
| Sweep crashes mid-batch | Cursor unchanged, batch replayed, the identity turns the replay into `:skipped` |
| Cursor falls behind | `lag_seconds` plus a health check with telemetry — a stalled dispatcher is a detected condition, not a support ticket |
| `COLLECT` returns N over the bound | `:failed`, `reason: :fan_out_exceeded`. Refusing loudly beats starting 50,000 processes |

---

## 10. What is genuinely hard, unresolved, or refused

**Hard, with a plan we are not certain about:**

1. **The guarantee in §2 is someone else's implementation detail.** A CI check that asserts the
   lock is still taken before the insert is possible but ugly; the note in `event_log.ex` is a
   linter, not a guarantee.
2. **Cursor lag under load.** One serialized sweeper per tenant is correct and is also a
   throughput ceiling. Batching helps; the ceiling is real and unmeasured.
3. **The ETS index is eventually consistent by 60 s.** A newly published trigger may miss the
   nudge for its first minute and be caught by the cron instead. Acceptable, and stated.

**Refused, so nobody re-proposes them:**

4. **A global cursor.** §2 — the NULL-tenant chain shares no lock space with the tenant chains.
5. **Automatic merge of a drifted definition.** §8.
6. **Migrating in-flight instances on rebind.** §8, and `ash_bpmn` usage rule 4.
7. **A trigger matching a process or decision resource.** §7.
8. **Rebuilding the requester's `ActorContext` in the dispatcher.** §6.
9. **Business data in the guard.** The guard sees the event's snapshot; the process re-reads
   its subject through Ash.

---

## Appendix — how the numbers in §2 were obtained

Two probes, both against the dev database inside `devenv`:

- **Lock scope**: transaction A takes `pg_advisory_xact_lock(12345, 678)` and holds 1500 ms;
  transaction B takes the same key. B's query returned `db=1500.3ms` and acquired 0 ms after
  A's commit point.
- **Lock spaces**: A holds `pg_advisory_xact_lock(0, 0)`; B takes `pg_advisory_xact_lock(0)`
  and acquires in **1 ms**.

The enclosing-transaction trace in §2 came from instrumenting `[:ash_enterprise, :repo, :query]`
across one audited create.

Reproduce before trusting any of it — that is the point of writing down how it was measured
rather than only what it showed.
