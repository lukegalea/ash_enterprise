# ADR 0029 — Process and decision configuration is tenant data, defaulting to a platform baseline

- **Status:** accepted
- **Date:** 2026-08-20

## Context

`ash_bpmn` versions a process definition by `key` + `version` and scopes it to a tenant. That is
enough for a tenant that authors its own processes and not enough for the thing an enterprise
platform actually sells: **the vendor ships a workflow, the customer changes part of it, and both
sides can still tell what happened.** The same is true of the decisions the processes route on.

So the question is not "can a tenant have its own definition" — it always could — but **what does a
tenant run when it has not said?** Every answer to that is a different product.

Three constraints were fixed before the design started, and each removed an option.

**A baseline cannot live in a NULL tenant.** `AshEnterprise.Platform.Resource` with `tenant?: true`
makes `organization_id` `allow_nil? false`, and `:base` plus `tenant?: true` raises by design. A
NULL-tenant baseline row is therefore not merely inconvenient, it is unrepresentable — and relaxing
the invariant would weaken tenancy for every resource in the application in order to serve one.

**A version number is per tenant.** Verified: `identity :unique_key_version, [:key, :version]`
defaults to `all_tenants?: false`, and `AshPostgres.MigrationGenerator` prepends the multitenancy
attribute, so the unique index is `(organization_id, key, version)`. Two tenants' version sequences
are independent whether anyone wants them to be or not.

**An in-flight instance pins its definition.** That is `ash_bpmn`'s own rule and it is not
negotiable here: migrating a running instance onto a definition it was never verified against can
leave a token standing on a node that no longer exists.

## Decision

**Which process or decision a tenant runs is data — a `Binding` row — and the absence of that row is
what "follow the platform baseline" means.**

Four commitments.

**1. The platform is a real organization, not a special case.** A seeded `Accounts.Organization`
with `unique_name: "platform"`, written by `Seeder.seed_platform_organization/0`. No business
units, no roles, no sign-in. Baselines are ordinary tenant-scoped rows that happen to belong to that
tenant, so every policy, every audit hook and every migration treats them like any other row. The
alternative — a nullable tenant column and a filter everyone has to remember — buys nothing and
costs the invariant above.

**2. No binding row means the platform baseline, latest published.** This is the load-bearing
default and the one that decides the product's shape:

* Provisioning a tenant writes **nothing**. There is no per-workflow backfill at onboarding, and
  there never will be one.
* A newly published baseline is live in every tenant that has not diverged, at once.
* Reverting a customization is **deleting a row** — which is why `unbind` is a `destroy` rather than
  a flag. A second way to say "follow the baseline" would eventually disagree with the first.

Any design where the default is a row is a design where onboarding means backfilling a row per
workflow forever, and where *never customized* cannot be distinguished from *customized and then
reverted*.

`AshEnterprise.Process.Resolver.resolve/3` reads in this order: a `Binding` with `source: :tenant`
returns that tenant's own definition; a `Binding` with `source: :platform` returns the **pinned**
platform version, because a tenant may deliberately hold at v3 while the platform is on v5; no
binding falls through to the latest published definition for the key in the platform organization.
Two indexed reads worst case, called **once per instance start** — never per advance, because the
instance has already pinned.

**3. Forking copies, and drift is reported rather than merged.** `Resolver.fork/4` creates a
tenant-scoped **draft** seeded with the XML of whatever that tenant runs today; publishing the draft
is what writes the binding, so an abandoned fork changes nothing. `AssignVersion` counts within the
tenant, so a fork of platform v5 is the tenant's **v1** — which is exactly why
`forked_from_version` is not optional: without it the lineage is unrecoverable and "you are two
versions behind" has no answer.

`Resolver.drift/1` therefore reports *"customized · forked from platform v3 · platform is now v5"*
and stops. It is deliberately **not** a diff and **not** a merge button. The two XML documents have
diverged, and reconciling them is the round-tripping problem of
[ADR 0008](0008-typed-invertible-legacy-mappings.md) wearing a different costume. Honest is "you are
behind", plus a side-by-side viewer.

**4. Processes pin and decisions do not, and the asymmetry is the point.** A process instance
resolves once and holds its `definition_id` for life. A business rule task with `binding="latest"`
resolves the decision **at the moment the node executes**, so a rule changed today applies to an
instance started last week.

> A process version is a *shape* — change it under a running instance and there may be no node where
> its token is standing. A decision is a *rule*, and the reason a business keeps its rules outside
> code is precisely that changing one takes effect without redeploying or restarting anything
> already in flight.

A process that must freeze a rule says so with `binding="pinned"` and a version.

**Baselines are code, not UI.** Publishing into the platform organization is impossible from the
web. Baselines live as reviewed artifacts in `priv/bpmn/*.bpmn` and `priv/dmn/*.dmn`, published by
`mix ash_enterprise.bpmn.publish` running as a system actor, idempotent by `content_hash` so a
deploy does not mint a new version of everything. Decisions publish before processes, because a
business rule task is verified against the decision it names. That is the same shape as `priv/legacy/schema.sql`
applied by `mix ash_enterprise.legacy.setup`, and for the same reason: a change to what every
customer runs should arrive through review, not through a form.

## Does it consume ActorContext?

**Yes for everything a tenant can see, and there is exactly one exception, which is named.**

`Binding` is `organization_owned`, audited, on the platform base — so who may rebind a workflow is a
role grant evaluated by the same union of grants as who may read one, and rebinding shows up in the
audit log without anyone being told to look for it. Definitions are the same.

The exception is the cross-tenant read. Steps 2 and 3 of resolution read a row owned by the platform
organization while acting for another tenant. That is the only legitimate cross-tenant read in the
design and it lives in **one named function**, `Resolver.load_platform_definition/2`, rather than as
`tenant: nil` sprinkled through the engine. It is defensible on three counts: the lookup is by
primary key or by `(platform_tenant, key, status)`; the target is immutable once published; and a
definition is not customer data. `Resolver.platform_tenant/0` is the one place that reads with
`authorize?: false`, and it reads a single organization id which it memoises in `:persistent_term`.

`AshEnterprise.Process.DefinitionLoader` is the same read for a *running* instance: the instance's
own tenant first, the platform organization second, through that same named function. It exists
because getting it wrong is quiet rather than loud — before it existed, an instance in a tenant
could not find its baseline, the token claimed, and the process sat at its start node with no error
anywhere.

## Consequences

**What this makes easy.** Two tenants running the same `key` at different versions, visible in one
list with the column that matters — *where the thing you are running came from*. Reverting a
customer's customization without a migration. Shipping a baseline fix to everyone who has not
diverged without touching a single tenant row. And a catalogue page that lists baselines alongside a
tenant's own, because a tenant that has forked nothing has no rows of its own and would otherwise be
told it has no processes rather than that it has changed none.

**What this makes hard, and it is the real cost.** A forked tenant is on its own. There is no merge,
so a baseline fix does not reach anyone who has diverged, and the only remedy on offer is "we can
tell you that you are five versions behind." For a platform whose whole argument is that
configuration should be data, that is the honest limit of the argument: data you can diverge is data
you can be stranded on. The mitigation is social rather than technical — fork the smallest thing that
needs forking — and this design does nothing to enforce it.

**What the platform organization costs.** It is a tenant that must be excluded from every tenant
listing, every usage report and every billing query, forever, and nothing in the type system says
so. One claim about it turned out not to be checkable at all: *"the platform organization has no
users"* cannot be asserted, because `Accounts.User` is `tenant?: false` — users are not scoped to an
organization, so the query returns every user in the system. The test asserts on business units and
roles, which are scoped, and the moduledoc says which claim is which.

**What the DSL would not say.** `identity :one_per_tenant, []` is the natural spelling of "unique on
the tenant column" and Ash rejects an empty key list. It has to be written the other way round —
`[:organization_id]` with `all_tenants? true` — which produces the identical index and is the only
form the DSL accepts. And Postgres treats NULLs as distinct in a unique index, so a NULL-tenant row
is not actually protected by it. Both are recorded in the moduledoc rather than implied.

**What it forecloses.** A cross-tenant *shared* definition that several named tenants co-own. The
model has exactly two sources, `:platform` and `:tenant`, and adding a third would reopen the
question the absent-row default closes.

## Reversal

**To drop per-tenant customization and keep baselines:** delete
`lib/ash_enterprise/process/binding.ex`, replace `Resolver.resolve/3`'s first two clauses with
`latest_platform_definition/2`, drop `process_bindings`, and remove `fork/4` and `drift/1` plus the
catalogue's provenance column. Every tenant then runs the platform's latest. Half a day. Existing
forks become orphaned tenant-scoped definitions that nothing resolves to — they are not deleted, so
the exit is recoverable.

**To drop baselines and keep per-tenant definitions:** the more invasive direction. Publish each
baseline into each tenant, make `source: :tenant` the only value, delete
`load_platform_definition/2` and `DefinitionLoader`, and remove the platform organization from the
seeder. The cross-tenant read disappears entirely, which is a genuine simplification; what is lost
is the ability to ship a change to everybody, which is the reason the design exists.

**What does not reverse** is the version numbering already assigned. A tenant's v1 that was forked
from platform v5 stays numbered 1, and any scheme that renumbers it breaks the pin on every
in-flight instance. `forked_from_version` is the only thing that makes those rows interpretable
afterwards, which is the strongest argument for it having been mandatory from the start.
