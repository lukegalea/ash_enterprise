# ADR 0023 — Impersonation adds attribution, never reach

- **Status:** accepted for the attribution half; the gate is proposed
- **Date:** 2026-08-19

## Context

Two findings, verified on 2026-08-19, that turned out to be the same finding.

**The provenance columns were never filled.** `AshEnterprise.Platform.SystemAttributes` declares
Dataverse's four provenance columns — `created_by_id`, `modified_by_id`, `created_on_behalf_by_id`,
`modified_on_behalf_by_id` — on every platform resource. A `grep` for `created_by_id` outside the
transformer that declares them returned nothing. No change, no preparation, no `relate_actor` ever
wrote to any of them. Every row in the system carried four null columns describing who was responsible
for it, which is worse than not having the columns at all: a reader sees the shape of an answer and
infers there is one.

**Impersonation had no representation.** Which is the privileged operation an enterprise buyer asks
about first, because it is the one where "who did this" has two correct answers and most systems keep
only one. A support engineer looking at a customer's account is routine; a support engineer's actions
being indistinguishable from the customer's own is a finding.

The columns were sitting there for exactly this. Dataverse's `*_on_behalf_by` fields mean "an
application or delegate did this for the user named in `created_by`", which is precisely the shape.

## Decision

**The subject stays the actor. The operator is recorded alongside, everywhere.**

`AshEnterprise.Security.Impersonation.acting_as(customer, operator)` returns the customer's user
struct carrying the operator's id in Ash metadata.
`AshEnterprise.Platform.Changes.StampProvenance` — new, applied by the base resource to every platform
resource — writes `created_by_id` from the actor and `created_on_behalf_by_id` from the operator, and
`AshEnterprise.Platform.Correlation` puts `impersonator_id` into every audit event's metadata.

**Authorization is unchanged by impersonation, deliberately.** The actor is the customer, so the
permission set is exactly what the customer could have done unaided. The alternative — an actor that
is somehow both — makes impersonation a privilege-escalation path rather than a support tool, and
makes the resulting audit trail unreadable, because nobody can tell afterwards which of the two sets
of permissions was in play.

**The key is absent rather than null when nobody is impersonating**, so `metadata ? 'impersonator_id'`
is the query for "every support access this month" without also matching ordinary activity.

**Provenance is stamped outside the `audit?` branch.** The columns come from being a platform
resource, not from being audited, so a resource with `audit?: false` still records who created and
last modified it. The change implements `atomic/3`, so it does not force `require_atomic? false` onto
every update action in the system.

## What is deliberately not decided here

**Who may impersonate whom**, and **the session** — a start, an end, a stated reason, and a
notification to the account owner. Both are needed before this is a complete break-glass story. They
are on the roadmap as `break-glass` and this ADR's status says `accepted` only for the half that
exists, because "impersonation is logged" and "impersonation is controlled" are different claims and
only one of them is currently true.

## Consequences

**What this makes easy.** A list view, an export or a policy can use `created_by_id` without joining
to the audit log — and, more importantly, it survives a retention window the log does not. Provenance
on the record and provenance in the log answer different questions and both are now answered.

**What it makes hard.** Nothing, at write time: two `force_change_attribute` calls on actions that
were already building a changeset. The cost is conceptual — there are now two places attribution
lives, and they can disagree if someone writes to the columns directly. Nothing does, and nothing
should.

**System actors still leave the columns null.** A system actor is a compile-time constant with no id,
so its attribution lives where it can: `system_actor` in the event metadata. "The nightly
reconciliation did this" and "we do not know who did this" stay distinguishable, which is the entire
reason `AshEnterprise.Platform.SystemActor` is a named constant rather than a nil.

## Does it consume ActorContext?

Yes — and notably it does not extend it. Impersonation is carried in actor metadata rather than as a
new `ActorContext` field, precisely because the authorization context must be the subject's and
nothing else. If the operator appeared in `ActorContext`, some check would eventually consult it.

## Reversal

Delete `lib/ash_enterprise/security/impersonation.ex`,
`lib/ash_enterprise/platform/changes/stamp_provenance.ex`, the `changes` block added to
`lib/ash_enterprise/platform/resource.ex` and the `impersonator_id` line in
`AshEnterprise.Platform.Correlation`. No migration: the columns predate this and stay. Under an hour,
and the columns simply go back to being null.
