---
name: new-resource
description: "Use when adding a new Ash resource to this application, or when deciding how a resource should be owned, tenanted, audited or exposed. Covers the platform base resource and the decisions it forces."
---

# Adding a resource

Every resource in this application uses `AshEnterprise.Platform.Resource`. That is
not a convention — it is where audit, telemetry, ownership, tenancy, soft delete,
lifecycle and authorization come from. A resource that uses `Ash.Resource`
directly has none of them, silently.

```elixir
defmodule AshEnterprise.Sales.Quote do
  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Sales,
    ownership: :user_owned,
    api_type: :quote,
    cdm_entity: "Quote"

  postgres do
    table "quotes"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id
    attribute :reference, :string, allow_nil?: false, public?: true
  end
end
```

Everything else — `owner_id`, `owning_business_unit_id`, `organization_id`,
`created_on`/`created_by_id`, `version_number`, `lifecycle_status`, the policy
set, the audit wiring — arrives from the base resource. Do not re-declare them.

## The decisions the base resource forces

### `ownership:` — get this right first

It mirrors Dataverse's OwnershipType and it decides **which authorization depths
even apply**. In Dataverse it is fixed at table creation and cannot change;
treat it the same way, because changing it later is a data migration.

| Value | Adds | Depths that work | Use for |
|---|---|---|---|
| `:user_owned` (default) | `owner_id`, `owner_type`, `owning_*` | Basic, Local, Deep, Global | Most business entities |
| `:business_owned` | `owning_business_unit_id` only | Local, Deep, Global | Security furniture: users, teams, roles |
| `:organization_owned` | nothing | Global only | Reference and configuration data |
| `:none` | nothing | Global only | Join tables, unowned system tables |

If the resource is derived from the CDM, **do not guess** — the real value is in
`priv/cdm/resolved/dataverse_*.json` under `dataverse.ownership_type`.

### `api_type:` — omit unless you mean it

Omitting it (the default) means the resource has **no public API surface at
all**. Only set it when the resource should be on JSON:API and GraphQL, and then
also add routes in the domain. Exposure is opt-in precisely so that adding an
internal resource never publishes it by accident.

Never expose Security or Audit resources: a filterable public API over the
authorization tables is a map of the security model.

### The opt-outs

`audit?`, `archival?`, `tenant?`, `lifecycle?`, `policies?` all default to `true`
(`policies?` and `audit?` especially). Turning one off is a decision that must be
**local and greppable** — `audit?: false` in a resource file can be reviewed in a
diff; a resource that silently never had auditing cannot.

Two opt-outs are structural rather than preference:

- the audit log itself must set `audit?: false`, or it recurses;
- `Token` is plain `Ash.Resource` — nobody owns a JWT jti, and soft-deleting a
  revoked token would defeat revoking it.

## After adding a resource

1. **`mix ash.codegen <descriptive_name>`** — Ash derives migrations as a diff
   against resource snapshots. Forgetting means the schema silently drifts, and
   `mix ash.codegen --check` fails in CI.
2. **`mix ash.migrate`**
3. **`mix ash_enterprise.seed --privileges-only`** — the privilege catalogue is
   derived from the resource list. A resource added without re-seeding has no
   privileges, which makes access to it **ungrantable**: a silent failure that
   presents as a permissions bug.
4. Register it in the domain's `resources do` block.

## Prefer adopting over inventing

Before writing attributes by hand, check whether the CDM already models this
entity — `priv/cdm/resolved/` has 43 resolved entities plus 18 from the Dataverse
reference. See the `cdm-adopt` skill. The corpus proposes; you dispose. Deleting
the 80% you do not need is the expected workflow, not a failure of the generator.

## Do not

- Hand-write migrations. Change the resource and regenerate.
- Re-declare platform attributes. They come from the extension.
- Use `forbid_if` for row access in policies. See the `policy-authoring` skill.
