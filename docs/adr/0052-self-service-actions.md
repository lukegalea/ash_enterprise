# ADR 0052 — Self-service actions: what a member may do for themselves without a grant

- **Status:** accepted (2026-10-15), implemented
- **Date:** 2026-10-15

## Context

Since 1b88b34 the grant checks answer a generic action with a boolean, not a row filter (Ash raises on a filter for a
generic action; ADR 0051's 2026-10-14 note). `RoleGrant` authorizes a generic action only on a `:global` grant, and
`SharedWithActor` and `HierarchyGrant` contribute `false`. That fix narrowed nothing, but it made a gap visible.

`MorningBrief.compose_today` is a generic action that composes **the actor's own** brief: it takes no owner, opens a
brief owned by the actor (`start_for_date` sets `owner_id` from the actor) and starts the `morning.brief` process with
the actor as `started_by`. A member without a `:global` MorningBrief grant could not run it, so the scheduled brief
(`MorningBriefWorker`), Today's Compose button and the ACP `compose brief` command all refused them, while Today told
them to "say `compose brief`" (dogfood log, 2026-10-14, Policy).

The role model cannot express the fix:

- A generic action maps to the `:read` verb (`AccessRight.for_action_type/1`) and has no row for a depth to reach, so
  the only grant that authorizes it is `:global`. On MorningBrief a `:global` read also reaches **every other
  member's** brief. Giving every member that grant so they can compose their own would widen exactly what has to stay
  narrow.
- A `:basic` grant ("records I own") is the right *shape*, but `:basic` means nothing for a generic action — there is
  no record to own until the action has made one.

Luke's decision (2026-10-15): any member may compose their own brief; composing is scoped to the actor by
construction, so it needs no MorningBrief grant. Composing someone else's brief is not something this action does,
and no way to do it is added.

## Decision

**A resource may declare actions self-service: things any active member of the tenant may do on their own behalf,
with no role grant.** The declaration is a `platform` option, passed through `use AshEnterprise.Platform.Resource`:

```elixir
use AshEnterprise.Platform.Resource,
  domain: AshEnterprise.Agents,
  self_service: [:compose_today, :start_for_date, :read, :latest]
```

A fourth grant path in the platform union, `AshEnterprise.Security.Checks.SelfService`, reads it:

| Declared action | Authorizes |
|---|---|
| generic | the action, outright: its implementation scopes itself to the actor |
| create / read | rows the actor personally owns (`owner_id` is the actor) — not their teams' |

It admits a person (a `user_id` in the context) whose account is active (`lifecycle_status == :active` on the actor)
acting in their own tenant (the call's tenant is the context's organization). Anything else contributes `false`, with
one allowance: a generic action asked about with no tenant at all is admitted, because `ash_acp` prunes its command
palette with `Ash.can?/3` and no options. That admits nothing by itself — a generic action has no rows, and every
read and write it makes names a tenant and is checked again. A create or read with no tenant is never admitted (with
`global? true` multitenancy a nil tenant reads across tenants).

The bounds are enforced at compile time by `AshEnterprise.Platform.Verifiers.SelfServiceActions`: every listed action
must exist; a create or read may be listed only on a `:user_owned` resource (there is no owner to bound it by
otherwise); updates and destroys cannot be listed — changing or removing an existing row is what a role is for.

MorningBrief declares `compose_today` (the action), `start_for_date` (the brief it opens), and `read` and `latest`
(the existing-brief check inside the action, and reading one's own brief back on Today). Everything the action does
downstream still runs under ordinary policies: the process engine's writes go through the engine bypass as before,
the draft's events are read as the reader under `CalendarEvent`'s own grants, and deciding the brief is the approval
task's business (`HumanTask`, organization-owned, unchanged). No other resource declares anything.

### Why this is still "authorization is data"

It is not a deny rule and it does not reorder anything: it is one more `authorize_if` in the union, so access is still
granted if any path grants it and no path subtracts (`docs/manifesto/03-authorization-is-data.md`). The conditions on
it — active, own tenant — are requirements of *this path*, not `forbid_if`s; failing one takes nothing from a role
grant.

What it is not is a row an administrator can edit. That is deliberate and narrow: the declaration is a fact about the
action's code (it is the actor's own by construction), reviewed in the diff that adds it, and it reaches no row the
actor does not own. An administrator who wants a member to see *other* people's briefs still does that with a role.

### Disabled accounts and dead tenants

The self-service path refuses a deactivated account by its own positive condition, and the scheduled path already
refused one (`Integration.Calendar.ActorLoader` cancels the job, `:user_inactive`). There is no platform-wide
disabled-account or decommissioned-tenant refusal yet — the `forbid_if`/bypass the manifesto reserves for those does
not exist — so a deactivated user who still holds roles is still authorized by `RoleGrant`, and nothing reads an
organization's lifecycle. That gap predates this record and is not widened by it.

## Does it consume ActorContext?

Yes, and it queries nothing. The declaration is compile-time DSL (`Spark.Dsl.Extension.get_opt/4`); the actor's id
and organization come from its `ActorContext`, its status from the actor struct the request already loaded, and the
call's tenant from the query, changeset or action input being authorized.

## Consequences

- Every active member can compose their own brief — on schedule, from Today, and over ACP — and read their own briefs
  back, with no MorningBrief grant. `compose` appears in the ACP palette for them (`Ash.can?/3` answers `true`).
- A member still cannot read, compose or decide another member's brief; `start_for_date` accepts no owner.
- A zero-grant member's brief opens its approval task on them, but deciding it needs read on `HumanTask`
  (organization-owned, so `:global`) — a role, as before.
- `MorningBrief.agenda` and `.pulse`, Today's report actions, are also generic actions that read as the actor; they
  are not declared here and stay `:global`-only. Declaring them is the same judgement, made separately.
- A new self-service action is a one-word change in a resource, visible in review and in `/clarity`'s policy
  diagram (the check's `describe/1`), and pinned by the conformance suite
  (`test/ash_enterprise/security/conformance_test.exs`, "self-service actions").

## Reversal

Remove the action from `self_service:`. It then falls back to the role model: a generic action needs a `:global`
grant, a create or read a grant at a depth that reaches the row.

## Note, 2026-10-17: acting on one's own row through a generic action

The agent chat (PROD-45) lets a member finish one of their own action items and unpin one of their own pinned apps.
An update or destroy still cannot be declared self-service. Each is instead a generic action that is declared:
`Canonical.Task.complete_mine` and `Assistant.PinnedApp.unpin`. Each one first finds the row through a
self-service read filtered on `owner_id == actor` (`:mine`), as the actor. Only then does it run the update or destroy
on that row, with the actor named on the write, so the audit entry is theirs. The bound is the lookup. Another
member's row is "not found", whatever roles the actor holds. Every other update or destroy on these resources still
takes a role grant. This is the "generic action that scopes itself to the actor by construction" case in the Decision
table, not a new grant path. Each such action is a reviewed declaration in its resource.
