---
name: cdm-adopt
description: "Use when adopting a new entity or problem domain from the Microsoft Common Data Model corpus into this application — the vendored schema, the resolver pipeline, and how to turn a resolved entity into an Ash resource."
---

# Adopting a CDM entity

Read `docs/manifesto/02-schema-commons.md` for why this exists. The short version:
do not invent your nouns when a mature published model already answers the
questions you have not thought of yet.

## What is already resolved

```
priv/cdm/resolved/
├── <entity>.json            # 43 entities from the CDM corpus
└── dataverse_<entity>.json  # 18 entities from the Dataverse table reference
```

Check here **before** writing any resource by hand. Each file carries flat
attributes with names, types, requiredness, max lengths, display names,
descriptions, and provenance back to the exact pinned commit.

## The hybrid corpus, and why

| Layer | Source | Maintained |
|---|---|---|
| Business entity structure | `microsoft/CDM` `schemaDocuments/` | **Frozen since 2023** |
| Security, audit, reference entities | Dataverse table reference | Monthly |
| **All option sets and lifecycle** | Dataverse table reference | Monthly |

The CDM contains **no security or audit model at all** — no `SecurityRole`,
`Privilege`, `Audit`, `PrincipalObjectAccess`, `FieldPermission`. It also
declares `is.constrainedList` but no entity ever uses it, so it cannot tell you
what any picklist value means.

That is why both scrapers exist and why they emit the same format.

## Adopting something already resolved

1. Read the JSON. Note `dataverse.ownership_type` — this is the `ownership:`
   value for the base resource and it is **not a guess**.
2. Write the resource using `AshEnterprise.Platform.Resource` (see the
   `new-resource` skill).
3. **Delete the 80% you do not need.** This step is mandatory, not optional. CDM
   entities are wide because they serve everyone: `Contact` has 214 attributes,
   `Organization` has 505. The corpus proposes; you dispose.
4. Set `cdm_entity: "EntityName"` so provenance survives.
5. `mix ash.codegen`, `mix ash.migrate`, `mix ash_enterprise.seed --privileges-only`.

## Adopting something not yet vendored

The corpus on disk is deliberately narrow. To widen it:

```bash
# 1. Add the path to SPARSE_PATHS in priv/cdm/tools/vendor.sh, then:
priv/cdm/tools/vendor.sh

# 2. Resolve the new entities to flat JSON (offline, one-time):
devenv shell -- python priv/cdm/tools/resolve.py --entity Opportunity

# 3. For security/audit/option-set data, scrape the Dataverse reference instead:
devenv shell -- python priv/cdm/tools/dataverse_docs.py --entity opportunity
```

⚠️ Adding `core/applicationCommon/foundationCommon` costs **~580MB**. Add the
specific accelerator path you need, never the whole subtree.

## Things that will bite you

**`Organization` is 505 columns.** It is a singleton settings table. Hand-write
the dozen fields you need; do not generate it.

**Intersect tables 404 in the Dataverse docs.** `teammembership`,
`systemuserroles`, `teamroles` are not published. `TeamMembership` *is* in the
CDM, which is the one case where the frozen corpus is the better source. For the
others, recover the shape from the `many_to_many` metadata on the parent entity.

**Name mismatches exist.** The CDM calls it `Currency`; Dataverse calls it
`transactioncurrency`. The foreign key is `transactioncurrencyid` in both.

**Lifecycle comes from the Dataverse half only.** State and status option sets
carry their correlation inline (`default_status` on a state, `state` on a
status), and that is what `AshEnterprise.Platform.Lifecycle` is built from.

## Do not

- Edit anything under `priv/cdm/schemaDocuments/`. It is vendored CC-BY-4.0
  third-party content pinned to a commit. Change the resource, not the corpus.
- Build a live fetch against the CDM. Upstream is frozen and the Schema Store was
  shut down in March 2024. There is nothing to fetch from.
- Drop the attribution. `priv/cdm/ATTRIBUTION.md` travels with any derived work.
