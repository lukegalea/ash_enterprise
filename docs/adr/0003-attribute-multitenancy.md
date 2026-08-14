# ADR 0003 — Attribute-based multitenancy plus a business-unit hierarchy

- **Status:** accepted
- **Date:** 2026-08-13

## Context

Multitenancy is the decision most painful to change later, because it is load
bearing for every table, every query and every policy. Ash supports two
strategies natively:

**`:attribute`** — a tenant column (`organization_id`) filtered on every query.
Works with any filtering data layer.

**`:context`** — native data-layer support. For AshPostgres this means **one
Postgres schema per tenant**.

There is a second, orthogonal axis that is easy to conflate with the first: the
structure *inside* a tenant. Dataverse answers it with hierarchical **business
units**, and [thesis 3](../manifesto/03-authorization-is-data.md) depends on that
hierarchy for the `Local` and `Deep` access levels.

These are genuinely different questions. "Which customer's data is this?" is
tenancy. "Which part of that customer's organization owns it?" is authorization.
A design that uses schema-per-tenant to answer the second — a schema per
department — collapses two concepts that need to move independently, and
departments reorganize far more often than customers are onboarded.

## Decision

**Attribute-based multitenancy on `organization_id`, plus a hierarchical
`BusinessUnit` tree inside each tenant.**

```elixir
multitenancy do
  strategy :attribute
  attribute :organization_id
  global? true
end
```

Applied by `AshEnterprise.Platform.Resource` to every resource, so tenancy is
inherited rather than remembered.

Three supporting choices:

**`organization_id` is CDM-native.** Every Dataverse table already carries an
`organizationid` column, so the tenant discriminator costs nothing in fidelity
to the schema commons — it is a column the model already has, given a job.

**`global? true`.** Reads without a tenant are permitted rather than erroring.
Without it, genuinely cross-tenant work — platform administration, the tenant
provisioning flow itself, the privilege catalogue — has no way to run, and the
workaround people reach for is disabling multitenancy on the resource, which is
far worse than the problem. The mitigation is that
`AshEnterpriseWeb.Plugs.LoadActorContext` sets the tenant centrally, so
application code never has to remember.

**Business units carry a materialized path**, making `Deep` an indexed prefix
match rather than a recursive query per policy evaluation.

## Consequences

**Easier**

- One schema, one migration path, one connection pool. Deploys are a single
  migration run.
- Connection pooling behaves normally. Schema-per-tenant fights poolers, because
  a pooled connection carries `search_path` state that must be reset per
  checkout.
- Cross-tenant queries are possible when legitimately needed (platform
  administration, usage reporting) rather than requiring a fan-out across
  schemas.
- Ash's tenant-aware identities let uniqueness be per-tenant or global per
  identity, which covers both `unique_email` (global) and
  `unique_name_per_business_unit` (scoped).

**Harder**

- **Isolation is logical, not physical.** A missing tenant filter is a
  cross-tenant data leak, where schema-per-tenant would have produced an empty
  result. This is the real cost and it is mitigated in exactly one place — the
  plug — rather than at every call site. `global? true` makes the failure silent
  rather than loud, which is the trade accepted for the workflows above.
- Very large tenants share table space with small ones. Partitioning by
  `organization_id` is available if that becomes a problem, and is a change to
  the data layer rather than the application.
- "Delete this customer's data" is a `DELETE` across tables rather than
  `DROP SCHEMA`.

**Foreclosed**

- Per-tenant schema customization. No tenant can have a column another lacks.
  That is a feature here: the alternative is a model that cannot be reasoned
  about globally.

## Reversal

Switching to `:context` (schema-per-tenant) is genuinely expensive, which is why
this ADR exists:

1. Change the `multitenancy` block in
   `lib/ash_enterprise/platform/transformers/add_system_attributes.ex` — one
   module, because tenancy is inherited.
2. `organization_id` columns become redundant; leaving them is harmless.
3. **Migrations become per-tenant.** Every deploy must run migrations for every
   schema, and a failure part-way leaves tenants on different versions. This is
   the single largest operational cost and the main reason it was not chosen.
4. `AshEnterprise.Release.migrate/0` must enumerate tenants.
5. Connection pooling needs revisiting.

Going the other way — attribute to context — is harder still, since it requires
physically relocating rows.

The business-unit hierarchy is **unaffected** either way, which is the point of
keeping the two axes separate.
