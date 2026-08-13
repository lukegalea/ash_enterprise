# Attribution — Microsoft Common Data Model

`priv/cdm/schemaDocuments/` contains schema documents from the **Microsoft Common Data Model**.

> Common Data Model schema documents
> © Microsoft Corporation
> Source: https://github.com/microsoft/CDM
> Licensed under the [Creative Commons Attribution 4.0 International Public License](https://creativecommons.org/licenses/by/4.0/legalcode) (CC-BY-4.0)

**Pinned at commit** `dd21d715e05ebf740a11356c80b5c3b4c38a89c2` (2025-01-22), the current `master` tip.

The upstream repository splits its licensing: documentation and content — which includes everything under
`schemaDocuments/` — is CC-BY-4.0 (`LICENSE`), while code under `objectModel/` is MIT (`LICENSE-CODE`). We vendor only
schema content, so **CC-BY-4.0 applies and attribution is required**. Ash resources generated from these documents are
derivative works; this notice travels with them.

The licenses grant no rights to Microsoft names, logos, or trademarks. Nothing in this project is affiliated with,
endorsed by, or a product of Microsoft, and the words "Dataverse" and "Dynamics" appear here only as descriptions of the
prior art we are modelling.

## What is vendored, and what is not

Only **unversioned** documents are kept. Upstream ships every entity as both `Entity.cdm.json` (current) and a series of
historical snapshots (`Entity.1.2.cdm.json`, `Entity.1.3.cdm.json`, …); the resolver reads only the former, so the
snapshots are dropped. Anything matching `\.[0-9]+(\.[0-9]+)*\.(manifest\.)?cdm\.json$` is excluded.

```
schemaDocuments/
├── foundations.cdm.json          # CdmEntity, entity shapes, the 70 core traits
├── primitives.cdm.json           # the dataType root hierarchy -> our Ash type map
├── meanings*.cdm.json            # semantic dataTypes (calendar, identity, location, …)
├── schema*.cdm.json              # the CDM metamodel
└── core/
    ├── cdsConcepts.cdm.json                 # the Dataverse trait layer (is.CDS.*)
    ├── wellKnownCDSAttributeGroups.cdm.json # cdsOwnershipInfo et al — our base resource
    └── applicationCommon/                   # 43 canonical business entities
```

The nested `foundationCommon/` subtree (CRM verticals, project service automation, and the automotive / education /
financial-services / healthcare / non-profit accelerators — the healthcare EMR accelerator alone is 336 entities) is
**deliberately excluded**. Vendoring it costs ~580MB for entities we do not model. When a future problem domain needs a
slice of it, extend the sparse checkout in `priv/cdm/tools/vendor.sh` for that path only.

## Why this is vendored rather than fetched

Upstream is frozen, not maintained. Last content release was **1.7.6 on 2024-02-23**; `schemaDocuments/core/` has been
untouched since **2023-03-30**; the object-model SDK has not shipped in any language since 1.7.6; and the CDM Schema
Store was **shut down at the end of March 2024**, after which the SDK's bundled definitions stopped including
application schemas entirely. There is no live source to fetch from, and no upstream changes to track.

Treat this directory as a frozen reference corpus. Do not build anything that assumes it will be updated.

## What the CDM does *not* contain

The CDM has **no security or audit model whatsoever**. Verified absent from `schemaDocuments/`:

`SecurityRole` · `Privilege` · `RolePrivileges` · `SystemUserRoles` · `Audit` · `PluginTraceLog` ·
`PrincipalObjectAccess` · `FieldSecurityProfile` · `FieldPermission` · `TimeZoneDefinition` · `LanguageLocale`

Those entities exist only in the **Dataverse table reference**, which — unlike the CDM — is actively maintained. They
are sourced separately by `priv/cdm/tools/dataverse_docs.py` from
[`MicrosoftDocs/powerapps-docs`](https://github.com/MicrosoftDocs/powerapps-docs) (also CC-BY-4.0), and emitted into
the same intermediate format. See `docs/adr/` for the reasoning behind the hybrid corpus.
