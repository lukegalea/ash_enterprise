---
name: policy-authoring
description: "Use when writing, debugging or reviewing Ash policies and authorization checks in this application. Covers the additive grant model, the forbid_if prohibition, and the rule that policy checks never query."
---

# Writing policies

Read `docs/manifesto/03-authorization-is-data.md` first. This skill is the
operational summary; that document is the argument.

## The model in one line

**Access is a pure union of grants. There are no deny rules.**

A principal may act on a record if **any** of three paths grants it, and the
paths never subtract:

1. **Role grant** — `(role, privilege, depth)` from `RolePrivilege`, unioned over
   direct roles and roles inherited through owner-team membership.
2. **Share** — an explicit `AccessGrant` row for the actor or one of their teams.
3. **Hierarchy** — manager or position chain, if enabled (off by default).

This comes straight from Dataverse: *"all privilege grants are accumulative with
the greatest amount of access prevailing."*

## The two hard rules

### 1. Never use `forbid_if` for row access

A single `forbid_if` breaks additivity and reintroduces order-dependence. Once
one exists, no grant can be reasoned about in isolation and every new rule
potentially interacts with every existing one.

`forbid_if` is legitimate **only** for concerns that are not row access at all —
a globally disabled account, a decommissioned tenant — and those belong in a
bypass or a plug, not in the per-record union.

```elixir
# Correct: each clause is one grant path; any one succeeding is sufficient.
policy always() do
  authorize_if AshEnterprise.Security.Checks.RoleGrant
  authorize_if AshEnterprise.Security.Checks.SharedWithActor
  authorize_if AshEnterprise.Security.Checks.HierarchyGrant
end
```

### 2. A policy check must never query

Everything a check needs — team ids, business-unit subtree, privilege map,
reporting chain — is precomputed **once per request** into
`AshEnterprise.Security.ActorContext` by `AshEnterpriseWeb.Plugs.LoadActorContext`.

Checks read precomputed sets and do set membership. **A check that issues a query
is a bug, not a slow path** — policy checks run on every read of every resource,
so a query there multiplies with rows returned.

If a check needs something the context does not have, add it to the context.

## Filter checks, not simple checks

Prefer `Ash.Policy.FilterCheck` for anything record-dependent, so **reads narrow
rather than raise**. A user listing records gets the subset they can see, not a
403.

This is better security as well as better behaviour: a forbidden error confirms
that a record exists. Ash applies the same filter as a predicate for writes, so
one implementation covers all four action types.

`Ash.Policy.SimpleCheck` is right only when the answer does not depend on the
record — `SystemActor` is the example.

## Depth semantics

| Depth | Reaches |
|---|---|
| `:global` | everything in the tenant |
| `:deep` | the scoping business unit **and everything beneath it** |
| `:local` | the scoping business unit only — **not** its children |
| `:basic` | records the actor owns, or one of their teams owns |

Depth is a **total order**: `global ⊃ deep ⊃ local ⊃ basic`. `:local` and `:deep`
are collapsed into a single id set at context-build time, so by the time a check
runs there is no hierarchy to walk.

A grant at a depth the resource's ownership model cannot support is **rejected at
assignment time** — `:basic` on an organization-owned resource reaches zero
records while reading in the UI as a restriction.

## Debugging

```elixir
# In config/dev.exs -- already set
config :ash, :policies, show_policy_breakdowns?: true

# Pre-flight a decision without performing it
Ash.can?({Resource, :read}, actor, tenant: tenant)
Ash.can?({record, :update}, actor, tenant: tenant)
```

The policy flowchart at `/clarity` renders the actual evaluation order, labelled
with each check's `describe/1` output. If a check's description is vague, fix it —
it is what someone reads off the diagram.

## Testing

`test/ash_enterprise/security/conformance_test.exs` is the truth table and the
first thing to read when the model surprises you. Add cases there rather than
testing authorization incidentally inside feature tests.

Phrase each test as the thing that must **not** happen. Every way to get
authorization wrong makes it more permissive, and none of them raise.
