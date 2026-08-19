# ADR 0024 — Audit retention: partition for age, crypto-shred for erasure

- **Status:** proposed
- **Date:** 2026-08-19

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
