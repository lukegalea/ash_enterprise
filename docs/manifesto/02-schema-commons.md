# Thesis 2 — The schema commons

> Do not invent your nouns. Adopt a mature published model — but adopt it as a frozen corpus, not a dependency.

## Nobody's first data model is good

Every enterprise project begins by inventing entities. `User`. `Company`. `Contact`. It feels like the cheapest possible
step, and it is where the expensive mistakes get made, because the questions that matter are not obvious in month one
and are very expensive in year three:

- Is a `Contact` a person, or a *role a person plays* at an organization? What happens when they change employer?
- Does a `Company` that is both a customer and a supplier get one row or two?
- Who owns a record — a user, or a group? Can that change? Does the record move business units when it does?
- Is an address a column set, a row, or a relationship? What about the second address?
- When an invoice is voided, is that a status, a state, or a different table?

Getting these wrong is not a refactor. It is a migration, a data-quality project, and a year of defensive code around
the seam.

Meanwhile, these questions were answered decades ago, repeatedly, by people with more at stake. Published enterprise
data models exist. Ignoring them to invent worse ones from scratch is not pragmatism; it is expensive.

## What we adopt

The **Microsoft Common Data Model** — specifically `schemaDocuments/core/applicationCommon/`, the 43 entities that form
the cross-cutting core of Dynamics 365 / Dataverse: `User`, `Team`, `TeamMembership`, `BusinessUnit`, `Organization`,
`Owner`, `Account`, `Contact`, `ActivityParty`, `Position`, `Currency`, and the activity and knowledge families.

Why this corpus rather than another:

- **It is machine-readable.** Entities are JSON with a formal trait system. Types, requiredness, max lengths, display
  names, option-set values, and relationship projections are all data, so resources can be *generated* rather than
  transcribed.
- **It is a real system's schema**, not a textbook's. Every column exists because a customer needed it.
- **It carries semantics, not just structure.** Traits like `is.CDS.owner`, `is.CDS.customer`, and `is.requiredAtLevel`
  tell us *why* a column exists, which is what lets a generator emit a polymorphic owner relationship instead of a bare
  uuid.
- **It is permissively licensed.** CC-BY-4.0. Attribution required, which we give in `priv/cdm/ATTRIBUTION.md`.
- **It is enormous, and modular.** Beyond the core sit finance and operations, healthcare, financial services,
  automotive, education, non-profit, retail, sustainability. When a new problem domain arrives, there is usually already
  a model for it.

That last point is the real prize, and it is what makes this a *strategy* rather than a one-off import: **the model
grows by adoption, not invention.** When the business says "we now need service contracts", the first move is to look at
what the corpus already says about service contracts.

## Adopt it frozen

Here is the part that requires honesty, because it is the weakness of this approach.

**The CDM is not maintained.** Verified as of August 2026:

- Last content release: **1.7.6, 2024-02-23**.
- `schemaDocuments/core/` last modified: **2023-03-30**.
- The object-model SDK has not shipped a release in any of its four languages since 1.7.6.
- The **CDM Schema Store was shut down at the end of March 2024**, and since SDK 1.7.1 the bundled definitions
  deliberately exclude application schemas.
- The documentation landing page still carries `ms.date: 2020-02-11`.

There is no formal deprecation notice. There is also no forward motion. Meanwhile the Dataverse table reference — the
same model, documented as a live product — is updated monthly.

The correct response is not to avoid the CDM. It is to **change what kind of thing we treat it as**. It is not an
upstream dependency to track; it is a *reference corpus to vendor*. So:

- It is committed into `priv/cdm/schemaDocuments/` at a **pinned commit**
  (`dd21d715e05ebf740a11356c80b5c3b4c38a89c2`).
- Nothing fetches it at build time. There is no network call in the pipeline.
- Every generated resource carries provenance: source, commit, document path, license.
- We are free to deviate. It is prior art, not a contract. Where the CDM is wrong for us, we change it and say why.

**Never build anything that assumes this corpus will be updated.** It will not be.

## The hybrid corpus

The CDM has one gap large enough to change the architecture: **it contains no security or audit model at all.**

Verified absent from `schemaDocuments/`: `SecurityRole`, `Privilege`, `RolePrivileges`, `SystemUserRoles`, `Audit`,
`PluginTraceLog`, `PrincipalObjectAccess`, `FieldSecurityProfile`, `FieldPermission`, `TimeZoneDefinition`,
`LanguageLocale`.

This is not a small omission for us — those are precisely the entities [thesis 3](03-authorization-is-data.md) is built
on. They exist only in the **Dataverse table reference**, as documentation rather than schema files.

So the corpus is hybrid, by necessity:

| Layer | Source | Format | Maintained? |
|---|---|---|---|
| Business entities | `microsoft/CDM` `schemaDocuments/` | `.cdm.json` | Frozen 2023 |
| Security & audit entities | `MicrosoftDocs/powerapps-docs` table reference | Markdown | Monthly |

Both are CC-BY-4.0. Both are vendored. Both are normalized into the *same* flat intermediate JSON, so the Elixir
generator has one input format and does not care which half an entity came from.

## The pipeline, and why part of it is Python

```
priv/cdm/schemaDocuments/*.cdm.json ─┐
                                     ├─► flat intermediate JSON ─► mix cdm.gen.resource ─► Ash resource
Dataverse table-reference markdown ──┘   (priv/cdm/resolved/)
```

The first arrow is not a parse. CDM entity documents are not flat schemas: reading one correctly means resolving trait
inheritance through purposes and dataTypes, flattening nested attribute groups (every entity wraps its own columns in an
inline group named `attributesAddedAtThisScope`), and executing `resolutionGuidance` to project foreign keys — including
`renameFormat`, `referenceOnlyAfterDepth`, and polymorphic references like the User-or-Team owner.

Microsoft's object model already implements all of that in `create_resolved_entity_async`. Reimplementing it in Elixir
would be hundreds of hours for a strictly worse result.

So the resolver is Python, and it runs **once, offline**. Its output — flat, boring JSON — is committed. Python is not
in the build, not in CI, and not a runtime dependency. The Elixir generator reads only the committed JSON.

This is the general principle: *put the ugly, stale, foreign-toolchain step behind a committed artifact.* The
complexity is paid once and never enters the daily loop.

## The workflow this creates

When a new problem domain arrives, the process is mechanical rather than architectural:

1. Look for it in the corpus. Widen the sparse checkout in `priv/cdm/tools/vendor.sh` to that path only.
2. Resolve those entities to intermediate JSON.
3. `mix cdm.gen.resource <Entity> --domain <Domain>` for each.
4. Delete the 80% of columns you do not need. **This step is mandatory** — CDM entities are wide because they serve
   everyone. `Organization` alone is ~500 columns of environment settings and is hand-written here for exactly that
   reason.
5. Add your actual business logic: the actions, calculations, and state machines that are genuinely yours.

Step 4 is where judgment lives, and it is why this is not a code generator you run and forget. The corpus proposes; you
dispose. What you get is a *starting point informed by thirty years of other people's mistakes* instead of a blank file.

See `.claude/skills/cdm-adopt/` for the executable version of this workflow.

## Further reading

- `priv/cdm/ATTRIBUTION.md` — licensing, provenance, what is vendored and what is not
- `priv/cdm/tools/` — the vendoring script, resolver, and docs scraper
- `docs/adr/` — the record of why the corpus is hybrid and frozen
