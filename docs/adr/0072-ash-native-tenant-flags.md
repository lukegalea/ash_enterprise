# ADR 0072 — Feature flags are tenant rows, resolved once into the actor's context

- **Status:** accepted (2026-11-14)
- **Date:** 2026-11-14
- **Supersedes:** [ADR 0016](0016-unleash-for-feature-flags.md) (FunWithFlags, not Unleash; proposed, never built)
- **Related:** ADR 0043 (automation authority is a grant), ADR 0059 (human-only actions narrow the bypasses); [thesis 3](../manifesto/03-authorization-is-data.md) (policy checks never query)

## Context

ADR 0016 chose FunWithFlags and was never built. Its own consequences section named the cost: a FunWithFlags table is a
plain Ecto schema, so a flip is not in the audit log, a flag is global rather than a tenant's, and its UI has no
authorization of its own. It said that an Ash resource for the flag definition would close that governance half, and
that what made targeting cheap was not FunWithFlags at all but `AshEnterprise.Security.ActorContext`, which already
resolves the person's tenant, teams and business unit once per request.

So the useful part of FunWithFlags here is its gate vocabulary (people, groups, a percentage of actors). Its store,
cache and cache invalidation solve a problem the context build already solves: the context is rebuilt at every request
and before every LiveView event, so it can carry the answer. The library would also add a dependency, a second store
and a protocol layer to maintain.

[Thesis 7, gap 11](../manifesto/07-what-we-do-not-have.md#11-feature-flags) is right that policies are not a substitute
for flags. A role named `beta_user` is a permission that has to be revoked from everyone once the feature ships.

## Decision

1. **A build declares its flags.** `AshEnterprise.Flags.Catalogue` reads the keys and what each turns on from
   configuration (`config :ash_enterprise, AshEnterprise.Flags.Catalogue, flags: %{...}`). A key is a code path in this
   build. An undeclared key is off everywhere and logged, so a mistyped key at a call site hides a feature rather than
   showing it to everyone.
2. **A tenant decides who sees a flag, with one row.** `AshEnterprise.Flags.Flag` is a platform resource: tenant-scoped,
   organization-owned, audited, under the grant union. A row may only name a declared key, one row per key per tenant.
   Its `state` is `:off`, `:on` (everyone in the tenant) or `:targeted`: named people, members of named teams, the
   subtree of named business units, and a percentage of people.
3. **The percentage is a stable bucket.** A person's bucket for a key is the first two bytes of
   `SHA-256(key <> ":" <> user_id)` modulo 100. It is the same at every request, on every node and after a restart, and
   independent between keys. Raising the percentage only adds people. There is no percentage-of-time gate: a feature that
   appears and disappears between one request and the next is not a rollout.
4. **The context resolves it, once.** `ActorContext.build/2` reads the tenant's rows that are not off in one query and
   keeps the keys that are on for the person in `flags`. A business-unit target needs the person's ancestors, which is
   one more query on the unit's materialized path, and only while some row targets a business unit. An automation
   principal acting for a person (`intersect/2`) keeps the person's flags. A system actor, a principal on its own and a
   person with no tenant carry none.
5. **Checking a flag never queries.** `AshEnterprise.Flags.enabled?/2` reads the context already attached to the actor.
   An actor with no context attached is answered false rather than having one built. A change to a row reaches a person
   at their next request or LiveView event.
6. **The deployment has a kill switch.** `FLAGS_OFF=key1,key2` turns those keys off in every tenant without touching a
   row, so removing a key restores what each tenant had chosen.
7. **Flipping a flag is a person's act.** The write actions are `human_only` (ADR 0059): no system actor, engine or
   automation principal reaches them, and a person needs a grant on `Flag`. Every create and flip is an audit event with
   the actor and the correlation id. People manage flags through the domain's code interface and
   `mix ash_enterprise.flags`, as a named person.
8. **A flag is never authorization.** No policy check reads a flag. A flag decides whether a code path is offered; a
   grant decides whether a person may use it. A gated action keeps its policies, and a flag that is on gives nobody a
   permission they did not hold.

## Consequences

**Made easy.** Per-tenant rollout is structural, not a group gate keyed on a tenant id. Who turned what on, and when,
is in the same audit log as the changes it caused. Targeting uses the teams and business units people are already
organised by. There is no new dependency, store or cache.

**Made hard.** The context build costs one more query per request and per LiveView event, two while a row targets a
business unit. The flag table is small and indexed by tenant, but it is on the hot path. The no-query rule binds policy
checks, not the context build, which already reads roles, teams, shares and tasks. A job that runs as a system actor sees
no flags; a job that should honour a person's flags runs as that person or as a principal acting for them.

**Not provided.** Environments (a flag is on or off in whichever database it reads), percentage-of-time, scheduled
flips, flag dependencies, and a management screen. The first flag gated in a deployment we operate, and a screen to flip
it, are chosen when a feature needs them.

## Reversal

The exposure is `AshEnterprise.Flags.enabled?/2` at each call site, the `flags` field on the context, one table and one
mix task. To adopt FunWithFlags or an OpenFeature provider later, re-implement `enabled?/2` over it and drop the table:
the call sites do not change. Revisit if a deployment needs environments or a vendor's approval flow, or if an
`ash_feature_flags` package appears that does what this does.
