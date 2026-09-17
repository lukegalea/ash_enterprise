# ADR 0035 — Compliance is projected from events

- **Status:** accepted
- **Date:** 2026-09-17

## Context

Two facts about this platform's compliance obligations forced a design:

1. **Compliance is a property of history.** "Is this customer KYC-clean?" is
   answered by rules evaluated over evidence — screening outcomes, identity
   confirmations, lifecycle state — that arrive at different times, from
   different systems, some of them the legacy estate. A compliance answer
   computed inside a request path is an answer that cannot be replayed, and a
   replayed answer that disagrees with the original is worse than no answer at
   all: it means the trail is lying about why a decision was made.
2. **The rules themselves must be data with a lifecycle.** The obligations
   change (a control escalates, a jurisdiction is added), the changes carry
   approvers and effective dates, and tenants tailor within bounds. Code
   deployed to a server has none of those properties; a versioned,
   content-hashed, immutably-stored artifact does.

The building blocks now exist as first-party packages (ADR 0009's pattern,
continued): `ash_rules` (rule IR, fact-schema DSL, evaluators),
`ash_compliance` (the control plane — catalogs, profiles, waivers, the fixed
layering precedence, compiled `PolicyBundle` snapshots — plus the finding
projection and the append-only evaluation log), and `ash_strangler`'s change
ledger, which is how the legacy estate's writes become events in the first
place.

The decision this ADR records is how the reference app wires them together:
the KYC vertical slice.

## Decision

**A subject's compliance state is a projection of compliance events under an
immutable rule bundle — never a column a request path writes, and never a
rules-engine call inside a read.**

Concretely:

* **One log for compliance facts.** `AshEnterprise.Compliance.EventLog` is a
  dedicated AshEvents log. The central audit log (ADR 0002) records every
  platform write and is tamper-evident; it is the wrong *contract* for this —
  its schema is owned by the chain, and the projector engine's drain names its
  own wake-up columns. A KYC review appends one event per control gap the
  tenant's active bundle declares; the gap list is read off the bundle, so the
  event set follows the rules without a second copy of them.
* **The projector owns the evaluation.** `AshEnterprise.Compliance.Projector`
  folds `kyc_reviewed` events through `AshCompliance.Projector.translate/3`:
  facts hydrate from the event, `AshRules` evaluates against the tenant's
  active bundle, and the result lands as finding ops plus an append-only
  `ComplianceEvaluation` — the projection answers "now", the evaluation log
  answers "what did the engine decide and why" (ADR 0021's distinction, in a
  second register).
* **The subject reads its own projection.** `ProjectedUser` exposes
  `kyc_status`, `compliant?` and `gap_count` as calculations over the finding
  rows — batched, point-in-time, no engine in the query path.
* **The legacy estate enters through the ledger.** `AshEnterprise.Legacy.User`
  now declares `ledger? true`: a legacy write durably records itself, the
  drain (`AshEnterprise.Ledger.UserDrainWorker`, at-least-once, Oban) projects
  it into `ProjectedUser` *and* appends the KYC review in the same
  transaction, attributed to the projection system actor. That closes the
  chain this platform exists to demo: **legacy write → ledger row → drain →
  canonical action → event → projector → finding.**
* **Rules are seeded, not embedded.** The KYC rule census lives in
  `use AshRules` modules and enters the control plane as revisions through
  `AshEnterprise.Compliance.Seeds` (catalog, controls, mandatory and
  non-waivable and strengthening layers, a tailoring profile that refines a
  strengthening rule, one bounded waiver, a drafted revision 2 for the
  replay story). `mix ash_enterprise.compliance.seed` is idempotent.

### The authorization envelope, stated honestly

`ash_compliance` ships no policies — they are the host's. But unlike
`ash_bpmn`'s resources (ADR 0009), which ship as *macros* the host
instantiates on `AshEnterprise.Platform.Resource` and so inherits the union of
grants wholesale, `ash_compliance`'s fourteen resources are concrete modules;
Spark builds policies into a resource at its own compile time, so this
application cannot attach its policy block to them. The envelope is therefore
layered:

* the **append path** is governed for real: `AshEnterprise.Compliance.EventLog`
  is host-owned and carries the policy block; it and the finding resource are
  in the privilege catalogue's governed set (`additionally_governed/0`), so
  recording a review is a `(role, privilege, :global)` grant, and the drain
  appends under the system actor;
* the **read door** is governed: `/app/compliance/*` sits behind
  `AshEnterpriseWeb.ComplianceAuth`, which requires the same read grant on the
  finding resource that the policies would have required;
* the **reversal** is recorded below — the policy gap closes when the package
  ships resource macros, and the door keeps working unchanged.

## Consequences

**Easy:** replaying any finding (delete the projection, re-fold the events,
compare — the test does exactly this); explaining any decision from the
evaluation log alone; changing rules as reviewed lifecycle acts
(validate → approve → activate) whose effect is provably the rule that changed
and nothing else; tenant isolation by construction (each tenant compiles its
own bundle; the content hash is what an auditor pins); inheriting the legacy
estate's people into the compliance program with system-actor attribution and
`unknown` — never compliant — for evidence the legacy row cannot supply.

**Hard:** compliance truth is eventually consistent — a review lands in the
log and the finding is current only as of the drain (the projector engine's
own checkpoint/dead-letter machinery is the operator surface for that lag).
The evaluation log is append-only and unpruned, by design. A tenant with no
active bundle cannot be silently compliant: reviews refuse and the projector
writes an error finding.

**Foreclosed:** evaluating rules inside request handlers, storing compliance
status as a mutable column, and waivers without bounds, approvers or
compensating controls — the compiler refuses the last of these outright.

## Reversal

The wire-up is narrow and greppable. To undo: delete
`lib/ash_enterprise/compliance/`, the compliance surfaces in
`lib/ash_enterprise_web/` (a2ui modules, `ComplianceA2uiLive`,
`ComplianceAuth`, the router's `:compliance_surfaces` session), the
`:ash_compliance` / `:ash_events_projections` / `:ash_strangler ledger_drain`
config blocks, the two dependencies, and the three migrations
(`add_compliance_ledger`, `add_compliance_control_plane`,
`add_projector_engine_tables`). `ledger? true` reverts to the pre-ledger
mapping in one line. The package's tables are namespaced by prefix, so the
drop is mechanical and touches nothing else.

The *authorization* half has its own reversal, in the opposite direction: when
`ash_compliance` ships resource macros the way `ash_bpmn` does, the fourteen
resources instantiate on `AshEnterprise.Platform.Resource`, the union of
grants applies to every action natively, `ComplianceAuth` degrades to a
menu-level convenience, and `additionally_governed/0` loses its two
compliance entries.
