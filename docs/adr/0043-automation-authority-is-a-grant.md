# ADR 0043 — Automation authority is a grant

- **Status:** accepted (2026-09-28); the principal, its grants and the intersection rule built (2026-10-29); no
  admission grant issued
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

## Built, 2026-10-29

The mechanism exists; what any principal may admit is still a per-family grant nobody has issued.

- **The principal.** `AshEnterprise.Platform.AutomationPrincipal` is the closed, compile-time list, beside
  `SystemActor` and separate from it. Its one entry is `evidence_admitter`. It has no bypass:
  `Security.Checks.SystemActor` never matches it, and an `ActorContext` for it is never a system context.
- **Its grants.** `Security.AutomationRole` assigns a role to a principal in a tenant, scoped to a business unit, the
  way `UserRole` does for a user. `ActorContext.build_automation/2` resolves those rows the way `build/2` resolves a
  person's. With no rows the principal can do nothing, which `automation_principal_test.exs` checks. A principal with
  no context attached also has no authority.
- **The intersection.** A principal runs only work a person asked for, and runs it on `ActorContext.intersect/2` of
  the two contexts, so it does only what both allow. For each `(resource, verb)`, a `:global` side yields the other
  side. Otherwise the result keeps the business units both reach, and the person's own records only when both sides
  hold `:basic`. Records the two reach by different routes are left out, so the intersection can refuse something
  both would allow but never the reverse. A share with the person survives only where the principal's grant is
  global. The principal is never a task candidate and has no reporting chain.
- **Paths for people only.** Self-service never admits a principal, even one acting for a person. The grant union
  does not apply to a principal on an action its resource declares `human_only` or `changes_authority`
  (`Security.Checks.GrantReach`), so a principal acting for an administrator still cannot assign a role. Assigning a
  principal's role and granting a start are themselves `human_only`. Every other action that changes who may do what
  is `changes_authority`, which narrows the union for principals alone and leaves people, system actors and the
  engines as they were (the seeder and the access-request process assign roles): `UserRole` `assign`,
  `assign_governed` and `destroy`; `Role` and `RolePrivilege` `create`, `update` and `destroy`; `TeamRole` `assign`
  and `destroy`; `TeamMembership` `create` and `destroy`; `User` `assign_to_business_unit`, `assign_manager` and
  `assign_position`, since a user's unit, manager and position are what `:local`, `:deep` and hierarchy grants reach
  from; `AccessGrant` `share`, `revoke_direct` and `revoke_inherited`; `Privilege` `create`; and revoking a
  principal's role or a start grant. Without
  it, a principal given role administration could assign roles, and could add privileges to its own role, widening
  every holder of that role (`automation_principal_test.exs`, "nor may it administer anyone's authority").
- **Starting an agent.** `Security.AgentStartGrant` holds one row per `(agent key, person or team)`, RFC 8693's
  `may_act`. A person asks with `AutomationPrincipal.start/3`, and the request is refused unless they hold the grant.
  The stored principal is `{automation, name, on_behalf_of, agent}`, and its RFC 8693 `act` form is kept in the
  invocation's `delegation`.
- **At every claim** (`Execution.Identity`) the person, the start grant and the principal's roles are all read again.
  A revoked role on either side narrows the intersection, so the target is refused. A revoked start grant, an inactive
  account, or a person who now belongs to another tenant fails the row before the target is tried. Each of these is
  `:denied`, and `reauth_test.exs` shows each one with no effect committed.
- **Attribution.** The principal's actor carries the person's id, so records it creates are theirs and
  `created_by_id` / `modified_by_id` name them. The audit entry adds `automation_principal`, `on_behalf_of_id` and the
  invocation's `invocation_key`.
- **Not built.** Work with no requester (schedules, process starts) waits for agent versions published as
  requesterless, so a principal with no person is refused at request and at claim. The admission action and its
  per-family filter check, the subject of this record, wait for the admission work itself.
