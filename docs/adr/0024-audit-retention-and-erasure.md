# ADR 0024 — Audit retention: partition for age, crypto-shred for erasure

- **Status:** proposed (erasure half built, 2026-10-12; partitioning not built)
- **Date:** 2026-08-19
- **Implementation note:** 2026-10-12, at the end of this record

## Context

`audit_events` has no retention policy. Nothing expires, nothing is partitioned, nothing moves to
cheaper storage. A twelve-month SOC 2 observation window is therefore satisfied by accident — the data
happens still to be there — rather than by a control, and the table grows without bound on the write
path of every action in the system.

[ADR 0020](0020-tamper-evident-audit-log.md) made the second half of this sharper rather than softer.
The log now actively refuses `DELETE`, and even with the trigger lifted, removing a row would break
the hash chain across the gap — which is the chain working as designed. So the collision that thesis 7
entry 5 has named since the beginning is now concrete: **GDPR Article 17 requires erasing a person's
data on request, and this log is built so that removing anything is detectable.**

Both halves are real and they pull apart. Retention-by-age wants rows to leave. Erasure wants
*specific* rows to leave, on demand, at any age. And the integrity guarantee wants nothing to leave at
all.

## Decision

**Two different problems, two different mechanisms. Do not let either solve the other.**

**Age: monthly partitions, ninety days hot.** `audit_events` becomes a partitioned table by
`occurred_at`. Recent partitions stay on fast storage for investigation; older ones are detached and
archived, and remain chain-verifiable because a partition boundary is not a chain boundary — the chain
is per tenant and ordered by `sequence`, so a detached partition carries a contiguous run whose links
still check against each other and against the tail of the partition before it.

**Erasure: destroy the key, not the row.** Personal data inside `data`, `changed_attributes` and
`metadata` is encrypted per data subject; an Article 17 request destroys that subject's key. The row
survives, the chain survives, the structural facts survive — *something happened, at this time, by
this actor id, on this resource* — and the content becomes permanently unreadable. AshEvents supports
this shape directly through its `cloak_vault` option, which encrypts event data and metadata, so the
work is key management per subject rather than a new mechanism.

This is a real trade and it should be stated rather than glossed: crypto-shredding is **not**
erasure in the strictest reading of Article 17. It is the reading regulators have generally accepted
where an immutable ledger is a legal requirement in its own right, and it is the only reading
compatible with an audit log an auditor will accept. A deployment whose counsel disagrees needs a
different answer, and should know that before choosing this architecture rather than after.

## Consequences

**What this makes easy.** Bounded storage, faster recent queries, and an erasure story that does not
require breaking the thing the audit log exists for.

**What it makes hard.** Key management becomes load-bearing: losing a subject's key is an
irreversible erasure, and a bug that reuses one across subjects erases more than intended. And a
detached partition is another artefact to prove the custody of.

**What it forecloses.** Rewriting history to remove an entry entirely. Deliberately.

**Ordering.** This depends on nothing and blocks the `controls` item's twelve-month claim, which is
why it is priority 1 despite being the least visible thing on the list.

## Does it consume ActorContext?

Yes, unchanged — the log stays where it is, so reads keep the tenancy and policy path
[ADR 0022](0022-audit-log-is-tenant-scoped.md) describes. Nothing external is introduced: retention is
a property of the log, and handing it to something outside the boundary would put the evidence chain
outside it too.

## Reversal

Partitioning is the invasive half: converting back means a table rewrite, and any detached partitions
have to be reattached first. Encryption is worse than invasive — it is one-way for anyone whose key
has already been destroyed, which is the point. **This is the least reversible decision in the set,
and that is the strongest argument for designing it before it is urgent rather than during an
incident.**

## Implementation note — the erasure half (2026-10-12)

Built because the dogfood deployment was about to receive real third-party content: the operator's VendorPM company
Slack and his personal Gmail and Calendar, through Nango (ADR 0011's dogfood deviations). The requirement was to be able
to "forget the key" for everything one connection brought in, including its audit trail, without breaking the chain.
**Partitioning is not built.** Nothing here changes how long `audit_events` keeps rows, so q36 stays open.

**What was built** (`AshEnterprise.Erasure`, `test/ash_enterprise/erasure_test.exs`,
[runbook](../runbooks/crypto-shredding.md)):

- **The unit is a scope, not only a data subject.** `Erasure.Scope` is `(kind, ref)` with
  `kind ∈ {connection, data_subject}`. The Decision above names the data subject. Ingested content needed a second
  unit, everything that came in through one connection, because provenance is the one fact every landed row knows
  about itself. One Slack message is about several people at once. Each row is sealed under exactly one scope.
- **Keys are data, wrapped.** `Erasure.Key` holds one AES-256-GCM data key per scope. The key is wrapped under a master
  key from configuration (`ERASURE_MASTER_KEY` in production; generated into `.devenv/state` in dev and per run in
  test; never committed), and the scope id is the additional authenticated data. Key reuse is refused three ways: a
  unique identity on `scope_id`, a unique identity on a fingerprint of the key bytes, and the AAD binding (a key moved
  to another scope does not unwrap). Sealed values carry their scope id in an authenticated header, so a rewritten
  header fails authentication instead of decrypting under the wrong key.
- **Encryption at rest is `ash_cloak`'s structure with a per-scope key.** `ash_cloak` supplies the `encrypted_*`
  columns, the sensitive arguments and the decrypting calculation. Its vault contract (`encrypt!/1`, no record) cannot
  reach a per-scope key, so `Erasure.Changes.SealUnderScope` does the encrypting from the changeset. Covered:
  `SourceObject.raw_payload`, `Message.body`, `Conversation.subject`/`participants`, `CalendarEvent.title`/`location`.
- **The audit log needed no `cloak_vault`.** The Decision points at AshEvents' `cloak_vault`, but that option encrypts
  the whole event under one vault key and cannot shred per scope. It was not needed: with the event log not cloaked,
  AshEvents records a sensitive argument as `null` in `data`, and `changed_attributes` carries `encrypted_*`, which is
  ciphertext already sealed under the scope key. Destroying the key therefore reaches the audit copy without touching
  an audit row, and the chain verifies unchanged (tested). `metadata` carries correlation and tenant ids only.
- **The shred** is `Scope.shred` (`Erasure.shred_scope/4`, `mix ash_enterprise.erasure.shred`). It is policy-gated to
  a human holding a global `write` grant, with no system-actor path and no `forbid_if`. The caller must type the ref to
  confirm. It deletes the key row and marks the scope shredded in one transaction. The shred is audited on `Scope`.
  The key is `audit?: false`, because a key recorded in a permanent log would survive every shred. After a shred, sealed
  values read as `%Erasure.Shredded{}`, a shredded scope refuses new writes (re-checked under a lock inside the write's
  transaction), and it is never reopened.

**Review fixes (2026-10-12, same day).** Independent review found plaintext paths the first cut missed; each now has
a regression test in `erasure_test.exs` or `ingestion_test.exs`:

- `MorningBrief.draft_text` was a stored, audited render of `CalendarEvent` titles and locations, so the compose's audit
  event kept them past a shred. The brief now stores `event_ids` only and `draft_text` is a calculation rendered on read
  (`Agents.Calculations.RenderDraft`); after a shred each line reads `[shredded]`. The calendar erasure test now sweeps
  the **whole** `audit_events` table for fixture content, so any future derived copy fails CI.
- `Canonical.Person.name`/`email` are `sensitive?`, so the audit log records them as `null`. The rows themselves are
  still plaintext and outside any scope (see below).
- A tap's non-zero exit carried its stdout (its RECORD lines) into the OpenLineage FAIL facet and `oban_jobs.errors`.
  `TapRunner.Exec` now returns the exit status only, and `TapWorker` reduces every failure reason to structure first.
- `SealUnderScope` re-checks the scope inside the write's transaction under a `FOR SHARE` lock, so a shred racing a
  landing either reaches the row or refuses it. Before, a row sealed just before a shred could commit under a shredded
  scope.
- Sealed attributes carry no `max_length`: Ash renders a failed constraint's value into the error message, and errors
  reach traces, Oban and BPMN incidents.

**What it does not reach**, stated here because a regulator will ask. The runbook has the full list:

- backups, WAL and dead tuples that still hold the *wrapped* key, which the master key can open until they age out;
- plaintext in audit events written before sealing existed, including briefs composed before migration
  `20261012060423_erasure_review_fixes`;
- `Canonical.Person` rows: names and emails stay plaintext in `canonical_people` (cross-source, upserted on email, so
  not sealable under one connection). They are out of the audit log, so removing them is an ordinary row delete, but a
  shred does not do it;
- Nango's own copies and tokens, until the connection is deleted;
- the provider's originals;
- logs and error reports that captured a payload;
- anything derived outside the sealed resources.

**Known follow-ups** (low severity, not built):

- *Landing identity excludes the scope.* `SourceObject` and the canonical upserts are unique on
  `[external_system, external_id]`, so a second connection landing the same pair takes the row over and re-seals it
  under its own scope; which shred reaches it then depends on sync order. Adapters must qualify `external_id` per
  connection (the `Erasure` moduledoc's Slack example now does). The fix is the scope in the identity, or refusing an
  upsert that changes `erasure_scope_id`.
- *Person sealing.* A keyed blind index (HMAC of the normalized email under a scope-independent key) as the upsert
  identity, with `name`/`email` sealed under a per-person `data_subject` scope, would let a shred reach the row.
- *Error scrubbing.* Removing `max_length` closes the known constraint path; a shared step that replaces the value on
  `InvalidArgument`/`InvalidAttribute` for sensitive fields before errors reach tracers, Oban or BPMN incidents would
  close the class.

`data_subject` scopes exist in the model, but nothing writes under one yet. Per-person erasure (q14) is therefore
partial, not shipped.

Status stays `proposed`. This record is not an `accepted, not built` one, so landing code does not flip it, and half
of its Decision is still unbuilt.
