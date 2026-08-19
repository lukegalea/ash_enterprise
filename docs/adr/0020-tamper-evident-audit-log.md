# ADR 0020 — The audit log is tamper-evident, by two mechanisms

- **Status:** accepted
- **Date:** 2026-08-19

## Context

"Append-only" was a property of the *application*. `AshEnterprise.Audit.EventLog` offered only a
`:read` action, so nothing written in Elixir could rewrite history. That is not the question an
auditor asks, and it was never the question the moduledoc was answering.

The question is whether history can be rewritten at all. Verified on 2026-08-18: `audit_events` had
no integrity protection of any kind, and anyone holding a `psql` connection — a migration, a
misdirected script, an operator, an attacker with the production credentials — could `UPDATE` a row
and leave nothing behind to say so. SOC 2 CC7.2 and ISO 27001 A.8.15 both ask for logs "protected
against alteration"; the honest answer was that they were not.

Two families of answer exist. **Prevention** stops the write: revoke the privilege, or refuse it in
the database. **Detection** makes the write visible afterwards: hash-chain the rows so altering one
invalidates every row after it. They fail in opposite directions. Prevention is total until someone
has enough privilege to lift it, at which point it offers nothing. Detection never stops anything,
and survives an attacker with `ALTER TABLE`.

## Decision

**Both, doing different jobs, and neither pretending to be the other.**

**The trigger prevents.** A `BEFORE UPDATE OR DELETE` trigger on `audit_events` raises. It is the
cheap, total answer to everything short of an operator who intends to defeat it. `REVOKE UPDATE,
DELETE` was considered and rejected: the owning role and any superuser ignore it, which in
development — where the app connects as `postgres` — means it enforces nothing at all and would read
as protection that is not there.

**The chain detects.** Every event carries the SHA-256 of its own contents concatenated with the
previous event's hash. Altering a row invalidates it and every row after it; removing one breaks the
link across the gap; inserting one with the trigger disabled leaves a row with no hash at all.
`mix ash_enterprise.audit.verify` walks the chains and reports the first break by sequence number,
distinguishing `:altered`, `:broken_link` and `:unchained` because they have different causes.

**One chain per tenant.** The obvious design is a single global chain, and it would serialize every
audited write in the system against every other. It would also be redundant: AshEvents already takes
`pg_advisory_xact_lock` on every audited action, keyed by the tenant of the resource being written
(`AshEvents.AdvisoryLockKeyGenerator.Default`, verified 2026-08-19). The serialization a chain needs
is therefore already held — *per tenant*. Chaining per tenant adds no contention that was not already
there; chaining globally would add a great deal.

It is also the better artefact. A customer can verify their own chain without being shown anyone
else's, which is what "audit my own trail" has to mean in a multi-tenant system.

**The digest is recomputed in SQL, not in Elixir.** `AshEnterprise.Audit.Chain` reuses the trigger's
own expression through a window function. Two implementations of one canonical form is how a verifier
ends up disagreeing with reality about nulls, JSON key order and timestamp formatting — and a
verifier that reports false breaks gets switched off, which is worse than not having one.

## Consequences

**What this makes easy.** Handing someone an export they can check rather than trust: the CSV carries
`sequence`, `previous_hash` and `hash`, so a recipient can re-derive the chain independently. And
answering CC7.2 with a test rather than a paragraph — the suite tampers on purpose, disabling each
trigger in turn, and asserts the break is found.

**What this makes hard, and it is the real cost.** Retention and erasure. An append-only table that
actively refuses `DELETE` is in direct conflict with a GDPR Article 17 request, and the chain makes it
worse: deleting a row would break the chain even if the trigger allowed it. This was already an open
gap; it is now a sharper one, and ADR 0024 is where it gets designed rather than deferred again.

**What it costs at write time.** One indexed lookup of the tenant's tail per audited write, plus a
SHA-256 over the event payload. Both inside a transaction that already holds the advisory lock.

**What it does not claim.** The trigger can be dropped by anyone who can `ALTER TABLE`. That is not a
flaw in the design, it is the reason the chain exists — but it does mean this is tamper-*evidence*
and not tamper-*proofing*, and the module says so in those words.

**TRUNCATE still works.** The trigger is row-level, deliberately: `mix ecto.reset` has to function,
and a `TRUNCATE` takes the whole table, which is conspicuous in a way a single altered row is not.

## Does it consume ActorContext?

Not applicable in the usual sense — this is not an external tool — but the equivalent question has a
good answer. The chain adds no authorization path of its own: reading the log is governed by the same
policy union as before, and the export streams through the ordinary action layer, so it is exactly as
wide as its requester. There is no privileged export path, because a second way to read the log would
be a second thing to get wrong.

## Reversal

Delete the two `custom_statements` blocks from `lib/ash_enterprise/audit/event_log.ex`, the four
attributes they fill, `lib/ash_enterprise/audit/chain.ex`, and
`lib/mix/tasks/ash_enterprise.audit.verify.ex`; regenerate. The columns drop, the triggers drop, and
the log returns to being append-only by convention. Roughly an hour, and nothing outside the audit
domain references any of it — `AshEnterprise.Audit.Export` would lose three of its thirteen columns
and keep working.

The one thing that does not reverse is the evidence already written: existing hashes stay in the
table, describing a chain nothing verifies any more.
