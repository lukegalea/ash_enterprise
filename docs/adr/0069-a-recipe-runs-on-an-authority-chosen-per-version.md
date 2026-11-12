# ADR 0069 — A recipe runs on an authority chosen per version

- **Status:** accepted (2026-11-09); built (2026-11-12)
- **Date:** 2026-11-12
- **Related:** [ADR 0043](0043-automation-authority-is-a-grant.md) (automation authority is a grant; amended the same
  day for this record), [ADR 0055](0055-consequential-acts-are-governed-invocations.md) (every consequential act is one
  governed invocation), [ADR 0059](0059-version-number-is-an-optimistic-lock.md) (human-only actions narrow the
  bypasses), [ADR 0066](0066-sign-in-doors-share-one-standard.md) (expiring grants)

## Context

A recipe is one versioned `AshEnterprise.Bpmn.Subscription` row: **when** a committed row lands in a tenant's audit
chain, **if** a FEEL guard (and optionally a DMN route) says so, **then** start a published process. It is detective:
it runs after the write has committed and never vetoes it. The row is `AshBpmn.Resources.Subscription` instantiated on
the platform base, so it carries the platform's policies, tenancy and audit.

The facts, verified on 2026-11-12 against this repository:

- **The event that fires a recipe is not a request.** The engine starts the process as its configured actor and
  records the event's actor as the instance's `started_by_id`. A service task that names a declared target runs as
  that person (`Process.ServiceInvocation`, ADR 0055). For a recipe that is a confused deputy: whoever happened to
  write the row becomes the authority for whatever the process then does.
- **The `authority` column (built 2026-11-11) already closes most of it.** `:human_tasks_only` is the default, and
  publish refuses a diagram with a service, send or script task or a call activity; `:causing_person` keeps the old
  behaviour only for the one key a reviewed config allowlist names; `:standing_grant` was refused everywhere until
  this record. The step checks again (`Process.RecipeAuthority`), because the diagram can change under a published
  recipe.
- **The macro has no option for extra actions,** but a host module can add attributes and an action after
  `use AshBpmn.Resources.Subscription`, and `human_only` passed through `base_opts` reaches the generated resource.
  Since 2026-11-11 the host's bpmn resources take `policies?: false`, so the macro's trailing engine bypass no longer
  lets an engine-marked principal reach a `human_only` action.
- **ADR 0043 left process starts out.** Work nobody asked for waits for agent versions published as requesterless, and
  a principal with no person is refused at request and at claim.

## Decision

**A person may publish a recipe version whose steps run within their own authority. The version records them as
accountable and holds a start grant of its own; its steps run as the `recipe_runner` automation principal acting for
them, on the intersection of the two, rebuilt at every claim.**

1. **Publishing is a person's act.** `Subscription.publish_granted` is `human_only`: a system actor, an automation
   principal and an engine-marked call are Forbidden. It restates everything the macro's `publish` does by module name
   (a test fails if a step `publish` carries is missing), sets `authority: :standing_grant` and nothing else, stamps the
   actor as `accountable_person_id` in a `before_action` hook (so a refused actor is Forbidden, not Invalid), and in
   the same transaction writes an `AgentStartGrant` keyed `recipe:<key>:<version>` held by that person. Plain
   `publish`, the setup path, still refuses `:standing_grant`.
2. **The grant is per version, and it ends.** Version 2 is a new key, so it never inherits version 1's grant. The grant
   carries `valid_until`, 365 days by default (`standing_grant_review_days`), counted like a role grant's (ADR 0066).
   Handover is a re-publish by another person; there is no transfer.
3. **A new principal, with no bypass.** `recipe_runner` joins the closed list of automation principals. Like the others
   it is governed by `AutomationRole` rows; with none it can do nothing.
4. **The step runs as the intersection.** At every step `RecipeAuthority` finds the dispatch that started the instance
   tree (walking `parent_instance_id`, so a call activity's child keeps the grant), rebuilds the accountable person from
   their grant rows in the instance's tenant, and checks the version's grant. The target is requested as that person
   marked to run as `recipe_runner` for the grant, and every claim of the invocation rebuilds
   `ActorContext.intersect(person, recipe_runner)` (`Execution.Identity`). A run can do only what the publisher can,
   what the runner holds, and what that version's diagram names.
5. **Fail closed.** A publisher who is deactivated, gone or now in another tenant, a grant revoked or past
   `valid_until`, a version with nobody accountable (`:requesterless`, which stays refused), or a job naming another
   tenant records `{:no_authority, reason}` at the step and runs nothing. A step the intersection may not take is
   rejected as it is requested (`not_permitted`), and a loss between request and claim fails the invocation as
   `:denied`.
6. **Only declared targets.** Under a standing grant only an action-invoker entry that names a declared target runs,
   through its invocation. A legacy entry (one that runs as the process actor or the instance's starter) is refused at
   publish and at the step; `grant_role` is one, so assigning a role is never a recipe's step. An `ash:call` binding is
   refused too.
7. **The cause is never authority.** The dispatch records who caused the event as `caused_by_id`. The tenant comes
   from the instance, never from a payload. The audit entry of the target's write names the principal, the person
   (`on_behalf_of_id`) and, as provenance, the dispatch, event and grant ids.

`human_only` and `changes_authority` actions stay closed to every automation principal, so a recipe runner cannot
assign roles, approve a human task or publish another recipe. A principal is never an approver or a task candidate
(ADR 0055). `SystemActor` never runs recipe work.

## Does it consume ActorContext?

**Yes, and only from rows.** The publisher's context is `ActorContext.build/2` of their grant rows, the runner's is
`build_automation/2` of its `AutomationRole` rows, and the step runs on their intersection, rebuilt at every claim.
Deciding whether a step has any authority (reading the dispatch, the subscription, the person and the start grant) is
claim logic, not a policy check: no policy check queries, and none uses `forbid_if`.

## Consequences

**What this makes easy.** A tenant can wire "when this happens, do that" without a person at the moment it happens,
and the answer to "on whose authority did this run?" is one row: the version, its accountable person and its grant.
Revoking the grant, deactivating the person or removing the runner's role stops the work at its next claim.

**What it makes hard.** `publish_granted` restates `publish`, so a validation the library adds to `publish` is missing
until the drift test fails and someone adds it. Runner roles are tenant-wide: the bound is the intersection and the
diagram, not a per-recipe role. A grant that lapses stops the recipe silently except for the `:no_authority` record;
a control that reports lapsing and orphaned grants is separate work.

**What it forecloses.** A recipe acting on the authority of whoever caused its event, outside the one allowlisted key.
A recipe inheriting authority from an earlier version. A standing grant created by the setup task, a pack, a system
actor or an automation principal.

## Reversal

Remove `publish_granted`, `StampAccountablePerson`, `WriteStartGrant` and `StandingGrantSteps` from the host
subscription, `recipe_runner` from `AutomationPrincipal`, and the standing-grant branch from `RecipeAuthority`,
`ActionInvoker` and `ServiceInvocation`; `RecipeAuthority` then refuses `:standing_grant` at the step, as it did before
this record. Drop the `accountable_person_id`, `caused_by_id` and `valid_until` columns with a regenerated migration.
Existing standing-grant versions stop running; their grants and audit history stay.
