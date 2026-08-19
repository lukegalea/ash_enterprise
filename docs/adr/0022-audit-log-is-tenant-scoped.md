# ADR 0022 — The audit log is tenant-scoped by multitenancy, not by a special check

- **Status:** accepted
- **Date:** 2026-08-19

## Context

Verified on 2026-08-18: `audit_events` had no tenant column. Its columns were `id`, `record_id`,
`version`, `metadata`, `data`, `changed_attributes`, `occurred_at`, `resource`, `action`,
`action_type` and `user_id`, and reading the log required a `:global` role grant.

That combination had a consequence nobody had written down: **a customer could not see their own
audit trail.** Not "could see too much" — could not see it at all. Their only route was through
someone holding a grant over every tenant's log, which is both a poor answer to "who changed this
contract" and the opposite of what per-tenant log isolation means.

It also could not be fixed by granting a narrower depth. `AshEnterprise.Security.Privilege` allows
`[:global]` and nothing else for an unowned resource, correctly: `:deep` and `:local` filter on
`owning_business_unit_id` and `:basic` on `owner_id`, and the audit log has neither. Every depth below
global reaches nothing on it, by construction.

The first design attempted here was a bespoke `AshEnterprise.Audit.Checks.OwnTenantTrail` filter
check: hold a grant at any depth, see your own organization's events. It worked, and it was wrong —
because it answered a tenancy question with an authorization mechanism, in a repository whose entire
argument is that those are declared separately and derived.

## Decision

**Give the audit log the same multitenancy every other resource has, and delete the special check.**

```elixir
multitenancy do
  strategy :attribute
  attribute :organization_id
  global? true
end
```

`organization_id` is filled by the chain trigger from the metadata
`AshEnterprise.Platform.Changes.StampCorrelation` stamps out of the changeset's tenant — so the column
is written by the database, filtered by Ash, and neither side takes the caller's word for it.

The two questions stay separate, which is the whole point. **Depth** answers *how much of a tenant may
you see*, and on the audit log the answer remains "all of it or none". **Tenancy** answers *which
tenant*, and it is enforced by the data layer rather than by a policy that could be wrong. A customer
administrator holds a global grant *within their organization* and sees exactly their own trail.

`global? true` is what lets both readings coexist: a request carrying a tenant — every ordinary
request, since `AshEnterpriseWeb.Plugs.LoadActorContext` sets one — is filtered to it, and a read with
no tenant spans everything, which is what a system actor and a cross-tenant investigation need.

## Consequences

**What this makes easy.** Per-tenant log isolation now holds by the same mechanism, and the same
conformance suite, that isolates everything else — `AshEnterprise.Security.ConformanceTest` already
proves tenant isolation survives authorization being wrong, and the log is now inside that guarantee
rather than beside it.

**What it makes hard, and it is a real edge.** `global? true` means a read with no tenant sees every
tenant's events. That is deliberate and it is also the failure mode
`AshEnterprise.Security.TenantResolutionTest` was written about: a request that fails to resolve a
tenant does not raise, it silently widens. The audit log inherits that risk exactly as every other
resource does — which is an argument for the existing test, not against this decision.

**Events with no tenant.** Registration before an organization exists, and system actors operating
outside one, produce events with a null `organization_id`. They are invisible to tenant-scoped reads
and visible to global ones, and they form their own hash chain.

## Does it consume ActorContext?

Yes, unchanged. `AshEnterprise.Security.Checks.RoleGrant` still decides *who* may read; the tenant
comes from `ActorContext.organization_id` by way of the request's tenant. What this ADR removes is a
second, audit-log-specific path — which is the outcome the bar is supposed to produce.

## Reversal

Remove the `multitenancy` block and the `organization_id` attribute, regenerate. Reading the log then
requires a global grant again and spans every tenant. Under an hour — but note that the chain index
and the export's tenant scoping both assume the column, so `AshEnterprise.Audit.Export` would become
a cross-tenant tool with no way to narrow it.
