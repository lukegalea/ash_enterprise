# ADR 0001 — The CDM is a frozen, hybrid, vendored corpus

- **Status:** accepted
- **Date:** 2026-08-13

## Context

[Thesis 2](../manifesto/02-schema-commons.md) argues for adopting a published enterprise entity model rather than
inventing one. Turning that into an implementation required answering three questions, and the honest answers were not
the expected ones.

### 1. Is the CDM maintained? No.

Verified 2026-08-13 against the live repository and API:

| Signal | Finding |
|---|---|
| Repo `archived` flag | `false` — not formally deprecated |
| Last commit to `master` | **2025-01-22** (`dd21d715`, a metadata patch) |
| Last content release | **1.7.6, 2024-02-23** |
| `schemaDocuments/core/` last modified | **2023-03-30** |
| Object-model SDK releases (C#/Java/Python/TS) | none since 1.7.6 |
| CDM Schema Store | **shut down end of March 2024**; since SDK 1.7.1 the bundled definitions deliberately exclude application schemas |
| Docs landing page | `ms.date: 2020-02-11` |
| Dataverse table reference, by contrast | updated monthly (`ms.date: 2025-10-31` and later) |

There is no deprecation notice and no forward motion. The application schemas are **GitHub-only** now — the Schema
Store shutdown means there is no service to fetch them from even if we wanted to.

### 2. Does the CDM cover the entities we need first? No.

We start with cross-cutting concerns: identity, access control, audit. **The CDM models none of the security layer.**
Verified absent from `schemaDocuments/`:

`SecurityRole` · `Privilege` · `RolePrivileges` · `SystemUserRoles` · `Audit` · `PluginTraceLog` ·
`PrincipalObjectAccess` · `FieldSecurityProfile` · `FieldPermission` · `TimeZoneDefinition` · `LanguageLocale`

Present and usable: `User`, `Team`, `TeamMembership`, `BusinessUnit`, `Organization`, `Owner`, `Account`, `Contact`,
`ActivityParty`, `Position`, `Currency`.

A second gap surfaced during implementation: the CDM **declares** `is.constrainedList` in `foundations.cdm.json` but
**no entity under `core/applicationCommon` ever uses it**. Every entity carries `stateCode`/`statusCode` as bare
integers with `_display` companions and no option-set members. So the CDM cannot tell us what any picklist value means,
and cannot supply the lifecycle model an `AshStateMachine` block needs.

### 3. Can we parse `.cdm.json` ourselves? We should not.

CDM entity documents are not flat schemas. Reading one correctly requires resolving trait inheritance through purposes
and dataTypes, flattening nested attribute groups (every entity wraps its columns in an inline group named
`attributesAddedAtThisScope`), and executing `resolutionGuidance` to project foreign keys — including `renameFormat`,
`referenceOnlyAfterDepth`, and polymorphic references such as the User-or-Team owner.

Microsoft's object model already implements this in `create_resolved_entity_async`.

## Decision

**Vendor, freeze, hybridize, and resolve offline.**

1. **Vendored at a pinned commit.** `priv/cdm/schemaDocuments/` holds the corpus at `dd21d715`, pruned from 587MB to
   6.3MB by dropping versioned snapshots (`Foo.1.2.cdm.json`) and the `foundationCommon` accelerator subtrees. CC-BY-4.0,
   attributed in `priv/cdm/ATTRIBUTION.md`. Re-vendoring is `priv/cdm/tools/vendor.sh`. Nothing fetches at build time.

2. **Hybrid corpus.** Two sources, one output format:

   | Layer | Source | Maintained |
   |---|---|---|
   | Business entity structure | `microsoft/CDM` `schemaDocuments/` | frozen 2023 |
   | Security, audit, reference entities | `MicrosoftDocs/powerapps-docs` table reference | monthly |
   | **All option sets / lifecycle** | table reference | monthly |

   Both are CC-BY-4.0. `resolve.py` and `dataverse_docs.py` emit the same flat JSON into `priv/cdm/resolved/`, so the
   Elixir generator has one input shape and does not care which half an entity came from.

3. **Resolution is offline Python, and its output is committed.** `resolve.py` uses
   `commondatamodel-objectmodel==1.7.6` (verified working on Python 3.14). Python is **not** in the build path, CI, or
   runtime. The committed JSON is the artifact.

4. **Structure from the CDM, option sets from the docs.** `SystemUser`, `Team`, `BusinessUnit`, `Position` and
   `Organization` are scraped as well as resolved — the CDM gives richer structural detail, the docs give the picklist
   members and the state/status correlation.

### Results

All 43 `core/applicationCommon` entities resolved (**2,389 attributes**) and 18 Dataverse entities scraped. The two
pipelines independently agree that `SystemUser` has **136 columns**, which cross-validates both parsers.

`Organization` came out at 505 columns of environment settings, confirming it must be **hand-written**, not generated.

The security model is now fully machine-readable: `Privilege.canBeBasic/Local/Deep/Global`,
`RolePrivileges.privilegeDepthMask`, `PrincipalObjectAccess.{principalId, objectId, accessRightsMask,
inheritedAccessRightsMask}`, and `FieldPermission.{canCreate, canRead, canUpdate, canReadUnmasked}`.

The lifecycle model resolved better than expected. State and status choices carry their correlation inline:

```
state_code  0 -> {label: "Active",   default_status: 1, invariant_name: "Active"}
status_code 1 -> {label: "Active",   state: 0}
```

`DefaultStatus` on a state plus `State` on a status *is* the transition table, so `AshStateMachine` blocks are derived
rather than transcribed.

## Consequences

**Easier**

- Reproducible and offline. No network in the build, no dependency on a dead service.
- Adopting a new domain is widening a sparse checkout and re-running two scripts.
- Provenance travels with every generated resource: source, commit, document, license.
- We are free to deviate — it is prior art, not a contract.

**Harder**

- Two source formats and two scripts instead of one.
- The scrapers are coupled to Microsoft's documentation layout. It is machine-generated and highly regular, but a
  redesign upstream would break `dataverse_docs.py`. Mitigated by the output being committed: a break blocks *adopting
  new* entities, never the build.
- No upstream fixes will ever arrive for the CDM half.
- CC-BY-4.0 obliges us to keep attribution intact in anything derived.

**Foreclosed**

- Tracking the CDM as a live dependency. There is nothing to track.

## Reversal

**To re-vendor or widen coverage:** edit `SPARSE_PATHS`/`CDM_SHA` in `priv/cdm/tools/vendor.sh`, re-run, re-resolve.
Adding `foundationCommon` costs ~580MB, so add the specific accelerator path instead.

**To abandon the CDM entirely:** the generated resources are ordinary Ash resources with no runtime dependency on
`priv/cdm/`. Delete the directory and the tools; nothing breaks. You lose the ability to generate *new* resources from
the corpus, and you must keep the attribution notice for what was already derived.

**To switch to live Dataverse metadata** (the `EntityDefinitions` OData endpoint) for authoritative, current data:
write a third emitter targeting the same intermediate JSON. Requires a licensed tenant, so it is not reproducible in
CI — which is exactly why it was not chosen.
