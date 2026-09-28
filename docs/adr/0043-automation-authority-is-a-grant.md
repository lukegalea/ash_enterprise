# ADR 0043 — Automation authority is a grant

- **Status:** accepted, not built (2026-09-28)
- **Date:** 2026-09-27
- **Amended:** 2026-09-28 — a grant names only a question version calibrated on data its optimiser never saw
- **Amended 2026-09-28 (acceptance):** accepted by the operator ("reviewed doctrine and approve"). Three conflicts with
  the existing doctrine are resolved here rather than left implied: system actors keep their bypass but the automation
  principal never has one; the `ai` system actor loses its bypass; thesis 5's human decision moves to the moment the
  grant is made

## Context

When a band table ([ADR 0041](0041-thresholds-are-dmn-earned-by-calibration.md)) says *admit*, something performs the
admission. Every write in this system is attributed, so the question "who admitted this fact?" needs an answer an
auditor can read — and "how much do we trust the model?" needs an answer an administrator can change.

The facts, verified on 2026-09-27 against this repository:

- **System actors bypass grants.** `AshEnterprise.Platform.SystemActor` is a closed, compile-time list of named
  non-human actors (`oban`, `replay`, `migration`, `seed`, `ai`, `process`, `projection`, `system`), deliberately not a
  resource so that nobody can mint new ones at runtime. `AshEnterprise.Security.Checks.SystemActor` is used as a
  `bypass` in the shared policy set: in its own words, a system actor is "not subject to grants".
- **One of them is `ai`**: "An AI agent acting without a human actor. Prefer the human's actor where one exists." As of
  2026-09-27 it carries the same bypass as the others.
- **[Thesis 5](../manifesto/05-agents-are-users.md) says writes need a human.** Policies answer *may this actor do
  this*; they do not answer *did anyone actually ask for this*. The agent console holds every model-proposed mutation
  for a person's approval, and the audit entry records the human.
- **[ADR 0023](0023-impersonation-is-attribution.md)** established that attribution is recorded alongside, never
  substituted: the subject stays the actor and the operator is written next to it.

Automatic admission is a write without a human at the moment it happens. Performed by a bypassing system actor, it
would be a write without a human *and* without a grant — the one combination the platform has otherwise avoided.

## Decision

**Automatic admission is performed by a named automation principal that is subject to grants. What it may admit is
`(role, privilege)` data — scoped by question family, tenant risk tier and tenant — that an administrator can inspect
and revoke.**

**The principal.** Automation principals are named in a closed, compile-time list, for the same reason system actors
are: the list of non-human actors should be auditable and closed. Unlike system actors, they are **excluded from the
`SystemActor` bypass**, and their `ActorContext` is built from grant rows exactly as a user's is. The first is an
evidence admitter; others follow only by adding to the list in a reviewed change. The exact representation — a new
struct beside `SystemActor`, or a flag on it that removes the bypass — is the implementer's; the property is not:
**an automation principal with no grant rows can admit nothing.**

**The grant.** A role carries the privilege to invoke the admission action on judgment rows, and the policy on that
action is a filter check over the set of `(family, risk tier)` pairs precomputed into the principal's `ActorContext`
once per request. No query in the check, no deny rule, no ordering: adding a family is inserting a row, removing one
is deleting it, and the union of grants is preserved ([thesis 3](../manifesto/03-authorization-is-data.md)).
Revoking automation for a family — because a calibration run regressed, a model changed, or an auditor asked — is a
grant change, effective on the next request, with no deploy. A grant may name only a question version whose calibration
run satisfies [ADR 0041](0041-thresholds-are-dmn-earned-by-calibration.md)'s optimisation-split rule, so a
machine-proposed wording ([ADR 0047](0047-learning-produces-proposals.md)) cannot inherit automation it did not earn.

**Attribution.** Every admitted fact records the principal as the actor and, alongside it, the ledger id, the model
digest, the band-table version and the matched row. "The evidence admitter admitted this, because observation X from
model Y matched band Z of table version V" is one audit row, not an investigation.

**Human entries win.** An automatic admission never overwrites or lowers a fact a human entered; it may only fill an
absence. A reviewer's override is an ordinary action by a human, and it supersedes.

**System actors keep their bypass; the automation principal never has one.** The two lists stay separate on purpose.
`oban`, `replay`, `migration`, `seed`, `process`, `projection` and `system` are deterministic platform machinery, and
the bypass is how they already work. An automation principal acts on a model's observation, so it is governed like a
user: no bypass, and authority only from grant rows.

**The `ai` system actor loses its bypass.** It is the one entry in the system-actor list that is driven by a model, and
a bypass for it would be exactly the ungranted, unattended write this record exists to prevent. It is removed from the
`SystemActor` bypass. Model-driven work runs either as the person whose request it serves, or as an automation principal
holding grants; `ai` survives, if at all, only as an attribution label with no authority of its own. It is never the
actor of an admission.

**The human decision moves to the grant.** Thesis 5's "writes need a human" is kept, and its moment changes for this one
case: the human decision is the act of issuing the grant — per question family, risk tier and tenant, by an
administrator holding that privilege, recorded and revocable — not a confirmation at the moment of each write.

**Pending, and marked so:** whether any family is ever granted to an automation principal at all. The mechanism is the
decision here; issuing a grant is a separate, per-family act, and the recommendation is conservative: *supports* only,
at very high probability, for low-consequence families; a `contradicts` result routes to a human at any confidence —
there is no silent auto-fail; never a high-consequence predicate.

## Does it consume ActorContext?

**Yes — this record is the case where it matters most.** The automation principal's authority is resolved into
`ActorContext` once per request, from rows, and read by a check that never queries, exactly as a person's is. That is
the whole point: the trust extended to a model becomes the same inspectable data as every other permission, instead of a
threshold hidden in configuration and a bypass hidden in a policy file.

## Consequences

**What this makes easy.** "Which decisions do we let the machine make?" is a query over grant rows, per tenant. Turning
automation off is revoking a grant. An auditor sees a distinct actor for automatic admissions and can sample them
([ADR 0041](0041-thresholds-are-dmn-earned-by-calibration.md)'s random audit).

**What it makes hard.** A new kind of actor sits between the closed system-actor list and ordinary users, and the
distinction — named like a system actor, governed like a user — has to be kept sharp in code review. Thesis 5's "writes
need a human" gains a scoped exception: the human decision is moved from the moment of the write to the moment of the
grant, which is a real change of meaning and is stated here rather than implied.

**What it forecloses.** Automatic admission under a bypass. Automation authority expressed as a configuration flag.
Any model-facing tool that admits, overrides or authorizes. Any model-driven actor with a bypass, `ai` included.

## Reversal

With no grants issued, every observation routes to the human lane and the principal is inert — which is also the
state before this record. Removing the mechanism is deleting the principal from the list, the admission policy's
filter check and the role rows; facts it admitted keep their attribution in the audit log. Restoring the `ai` bypass is
a one-line change to the system-actor check, and would need a superseding record, because it reintroduces a model-driven
write with neither a human nor a grant behind it.
