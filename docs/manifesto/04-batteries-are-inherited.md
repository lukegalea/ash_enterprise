# Thesis 4 — Batteries are inherited, not installed

> One base resource. Audit, telemetry, ownership, tenancy and soft-delete arrive by inheritance, not by discipline.

## "Batteries included" usually means "batteries available"

Most frameworks that claim to be batteries-included mean that the batteries exist and are documented. Wiring them into
each new entity remains your job. The result is predictable: the first ten resources are wired correctly, the eleventh
is written under deadline, and eighteen months later a compliance audit discovers that one table has no history.

The concerns in question are not optional-per-entity. If a record can be changed, the change must be audited. If a
record exists, it belongs to someone. If the system is multi-tenant, *everything* is. Treating these as per-resource
decisions is treating a system invariant as a coding convention — and coding conventions decay.

## The mechanism

Ash resources are built on Spark, a DSL toolkit that supports **base resources**: a module that presets extensions,
sections, and defaults, which concrete resources then `use`.

That is the whole idea. `AshEnterprise.Platform.Resource` is the single place the cross-cutting concerns are declared.
Every resource in the application uses it, and a resource that does not is a bug a linter can find.

```elixir
defmodule AshEnterprise.Accounts.Team do
  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Accounts,
    cdm: [entity: "Team", ownership: :business_owned]

  # From here down: only what is actually specific to Team.
  attributes do
    attribute :name, :string, allow_nil?: false, public?: true
  end
end
```

What that one `use` line supplies:

| Concern | What arrives |
|---|---|
| **Ownership** | `owner_id` (polymorphic user-or-team), `owning_business_unit_id`, `owning_user_id`, `owning_team_id` |
| **Provenance** | `created_on/by/on_behalf_by`, `modified_on/by/on_behalf_by`, `overridden_created_on`, `import_sequence_number` |
| **Lifecycle** | `state_code`, `status_code` |
| **Concurrency** | `version_number`, wired to Ash optimistic locking |
| **Multitenancy** | `organization_id` and the `multitenancy` block |
| **Authorization** | the policy set from [thesis 3](03-authorization-is-data.md) |
| **Audit** | `AshEvents` — every action lands in the central event log with actor and transaction id |
| **Soft delete** | `AshArchival`, with cascade to related records |
| **Observability** | notifiers and the `Ash.Tracer` hook, so every action emits telemetry and OpenTelemetry spans |
| **Surfaces** | admin, JSON:API and GraphQL derivation defaults |

None of that is written per resource, and none of it can be forgotten.

## Why the attribute list looks the way it does

It is not invented. It is the CDM's own cross-cutting attribute groups —
`cdsOwnershipInfo`, `cdsCreationModificationDatesAndIds`, `cdsStateAndStatus`, `cdsVersionTracking`, `cdsTimeZoneInfo` —
transcribed.

There is a subtlety worth recording, because it surprises everyone who reads the corpus expecting inheritance to work
the obvious way: **the CDM's `CdmEntity` base entity is empty.** `extendsEntity: "CdmEntity"` contributes zero
attributes. The universal system columns live in *attribute groups* that each entity references, not in a base type.

The CDM expresses "every entity has these columns" through composition. Our base resource expresses the same thing
through inheritance, because that is the idiom Spark gives us. Same invariant, different mechanism — which is exactly
the kind of deviation [thesis 2](02-schema-commons.md) says we are free to make, as long as we say why.

## The escape hatch, and its limits

Uniformity that cannot be escaped becomes an obstacle. Some resources genuinely differ: join tables have no meaningful
owner; reference data like `Currency` is organization-owned and global; the audit log itself must not be audited, on
pain of infinite regress.

So the base resource is parameterized rather than rigid:

```elixir
use AshEnterprise.Platform.Resource,
  domain: AshEnterprise.Reference,
  ownership: :organization_owned,   # only Global/None depths apply
  audit: false,                     # this IS the audit log
  archival: false                   # immutable; never soft-deleted
```

The rule is that **opting out is explicit, local, and greppable**. `audit: false` in a resource file is a decision
somebody made on purpose and can be reviewed. A resource that silently never had auditing is not.

## Audit: one log, not two

Ash offers two auditing extensions and they solve different problems, so the choice is worth stating rather than
defaulting into:

- **`AshPaperTrail`** creates a `*_versions` table per resource. Excellent for "show me this invoice as it was in March"
  — the history is queryable, typed, and local to the resource.
- **`AshEvents`** writes a single central event log across all resources, with actor attribution, event versioning, and
  replay.

We default to **AshEvents**, for three reasons. It matches the shape of the Dataverse `audit` entity we are otherwise
modelling — one table, `action` / `operation` / `object_id` / `user_id` / `transaction_id` / `changed_data`. Compliance
questions are overwhelmingly cross-entity ("everything user X did last Tuesday"), which a central log answers with one
query and per-resource tables answer with a union across every table in the system. And it gives us a transaction id
that ties every write in a single transaction together, which is what makes an audit trail reconstructible rather than
merely present.

`AshPaperTrail` is available per-resource (`paper_trail: true`) for the entities that genuinely need queryable version
history. **Running both by default would double every write for a benefit most resources never use**, so we do not.

## Telemetry: the same argument, one level down

Ash emits `:telemetry` events for every action, changeset, query, validation, change, and calculation, and supports a
pluggable `Ash.Tracer`. Both are configured once, in `application.ex` and `config/`, and every resource is instrumented
by virtue of being a resource.

A correlation id is threaded through the actor context onto every event and span — the pattern borrowed from
Dataverse's `plugintracelog`, which pairs a `correlationid` with a `depth` so nested action invocations can be
reconstructed and runaway recursion can be caught.

There is nothing to remember when adding a resource, which is the entire point. The measure of this thesis is not that
observability is possible; it is that **forgetting it requires effort**.

## Further reading

- `lib/ash_enterprise/platform/resource.ex` — the base resource
- `docs/adr/` — the AshEvents-vs-AshPaperTrail decision in full
- [Ash: writing extensions](https://hexdocs.pm/ash/writing-extensions.html)
