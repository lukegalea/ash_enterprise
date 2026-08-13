# ADR 0002 — AshEvents as the default audit layer, AshPaperTrail opt-in

- **Status:** accepted
- **Date:** 2026-08-13

## Context

Auditing is non-negotiable for the class of application this template targets, and it must arrive by inheritance rather
than per-resource discipline ([thesis 4](../manifesto/04-batteries-are-inherited.md)). So the base resource has to pick
a default, and the choice is consequential because it is applied to every resource in the system.

Ash offers two mature options, which solve *different* problems despite both being described as "auditing":

**`ash_paper_trail`** (0.6.0, ~261k downloads) creates a `*_versions` table **per resource**. Configurable
`change_tracking_mode` (`:snapshot` / `:changes` / `:full_diff`), optional `belongs_to_actor`, and versions can be
exposed through the API. Its strength is *reconstruction*: "show me this invoice as it was in March" is a typed,
indexed, local query.

**`ash_events`** (0.7.0, ~47k downloads) writes a **single central event log** across all resources, with actor
attribution across multiple actor types, event versioning (old event versions can be routed to different actions on
replay), changed-attribute capture, and full **event replay**.

A third option — run both — was considered and rejected.

The application also models the Dataverse `audit` entity, whose shape is a single table keyed by
`action` / `operation` / `objectid` / `objecttypecode` / `userid` / `callinguserid` / `transactionid` / `changedata`,
where `transactionid` carries *the same GUID for every audit row written in one transaction*.

## Decision

**`AshEvents` is the default**, applied by `AshEnterprise.Platform.Resource` to every resource.

**`AshPaperTrail` is opt-in per resource**, via `use AshEnterprise.Platform.Resource, paper_trail: true`.

Three reasons, in order of weight:

1. **Compliance questions are cross-entity.** The real questions are "everything user X did last Tuesday", "every change
   to any record owned by this business unit", "what happened in the transaction that produced this bad state". A
   central log answers each with one indexed query. Per-resource version tables answer them with a `UNION` across every
   table in the system — a query that must be regenerated whenever a resource is added, and that nobody maintains.

2. **It matches the model we are already implementing.** A single log with `action`, `operation`, `object_id`,
   `user_id`, and a shared `transaction_id` *is* the Dataverse `audit` entity. Choosing `ash_paper_trail` would mean
   modelling one thing in the domain layer and a different thing in the audit layer.

3. **Transaction correlation is the property that makes an audit trail usable.** A trail that records changes but not
   *which changes happened together* cannot reconstruct an operation. `ash_events` gives us one event stream where that
   grouping is natural; per-resource tables make it a join across tables you must know to look in.

**Running both by default is rejected** because it doubles the write volume of every action in the system to serve a
per-record-history use case that most resources never have. Where that use case is real — a contract, a price list, a
regulatory filing — `paper_trail: true` is one word on that resource.

`ash_events` is **tier 2** ([thesis 6](../manifesto/06-reversibility.md)): 0.7.0 and less widely deployed than
`ash_paper_trail`. That is a real risk and is accepted knowingly, mitigated by the reversal path below.

## Consequences

**Easier**

- One place to query for any audit question; one retention policy; one export for an auditor.
- Actor attribution is uniform, including non-human actors — an Oban job, an MCP tool call, the system itself.
- Event replay is available, which makes rebuilding a projection or recovering from a bad deploy tractable.
- The audit taxonomy is not invented: the verified Dataverse `audit_action` option set (Create, Assign, Share, Merge,
  Approve, Reject, Submit, `Assign Role To User`, `Add Privileges to Role`, …) becomes our canonical action vocabulary.

**Harder**

- "This record's history" is a filtered scan of one large table rather than a small local one. The event log needs
  deliberate indexing on `(object_type, object_id, created_on)` and will want partitioning by time before it gets big.
- The event log is append-only and immutable, which collides with GDPR right-to-erasure. Flagged in
  [thesis 7](../manifesto/07-what-we-do-not-have.md#5-data-retention-purge-and-right-to-erasure); it is a design problem
  we have named rather than solved.
- The audit resource itself must be exempt from auditing (`audit: false`) or it recurses.
- Betting on the less-adopted of the two packages.

## Reversal

Switching the default to `ash_paper_trail`:

1. Change the extension list and the audit block in `lib/ash_enterprise/platform/resource.ex` — one module.
2. Run `mix ash.codegen` to generate the per-resource `*_versions` tables.
3. Re-point audit queries in `lib/ash_enterprise/audit/` at the new tables.
4. Historical events stay readable in the old table; there is no data migration unless you want one.

Because both extensions are configured in exactly one place, no resource file changes. That is the whole reason the base
resource exists.

Running both temporarily during a transition is supported — the objection to it is cost, not correctness.
