# ADR 0010 — Meltano for ingestion, Airbyte as the named fallback

- **Status:** proposed
- **Date:** 2026-08-18

## Context

[Thesis 7 §6](../manifesto/07-what-we-do-not-have.md) records that Ash reaches operational stores well and
analytical stores not at all, and concludes: plan on ETL *out* to the warehouse. The inbound direction has no
answer at all. Nothing in this repository lands third-party data, and that is the foundational gap — lineage
(ADR 0012) and cataloguing (ADR 0013) describe data movement, so they are vacuous until something moves data.

The tempting answer is to build ingestion here. Reactor and Oban are already dependencies, a Singer tap is
"just" a paginated HTTP client, and an `Ash.Resource` per remote object looks tidy. It is the wrong shape for
one reason: **a connector breaks when somebody else changes their API**, not when our model changes. Owning six
hundred of those is a maintenance surface with no relationship to this application's domain, and the
declarative-derivation argument does not apply — there is nothing to derive from, because the remote schema is
not ours to declare.

### The two candidates, verified 2026-08-18

| | Meltano | Airbyte |
|---|---|---|
| Licence | **MIT** (LICENSE on `main`; GitHub API reports `MIT`) | **Elastic License 2.0** for platform *and* connectors |
| Latest release | v4.2.2, 2026-07-22 | 2.2, 2026-08-10 per docs release notes |
| Last commit to default branch | 2026-08-13 | 2026-08-18 |
| Connectors | Singer taps/targets; MeltanoHub advertises 600+ | 600+ replication connectors (catalogue UI: 622) |
| Pipeline definition | `meltano.yml`, a required project file, made for version control | GUI/API-defined connections; state in Airbyte's own database |
| Gated behind a paid tier | nothing found | SSO, RBAC, multiple workspaces, SCIM |
| Emits OpenLineage | **no** | **no** |

Three of those rows deserve emphasis because they cut against the expected story.

**Airbyte's licence got worse, not better.** The familiar "ELv2 platform, MIT connectors" split **no longer
holds**: connectors were migrated from MIT to ELv2 in July 2025, and the docs now scope MIT to the Airbyte
Protocol only. For a repository whose thesis 6 treats open-source-only as a requirement, the fallback is
source-available, not open source.

**Meltano's stewardship has changed twice.** It left GitLab, became Meltano Inc, launched a commercial product
(Arch) which then shut down, and the open-source project is now stewarded by Matatika — whose own about page
says the two "came together under the Meltano name" in 2026. The project is not dead (a release three weeks
ago, commits five days ago) but the steward is a small company and not a foundation. *The precise ordering of
the Arch launch and shutdown posts could not be pinned down and is recorded here as approximate.*

**Neither tool emits OpenLineage.** Meltano's SDK roadmap lists it as planned and never marked done; the only
integration is an unofficial third-party repository last touched in 2023. A GitHub code search across
`airbytehq/airbyte` for `OpenLineage` returns zero results, and the 2024 feature request is stale. Airflow's
OpenLineage provider can emit lineage for its *Airbyte operator*, which is Airflow-side instrumentation, not
Airbyte's. This is a direct dependency for ADR 0012 and is dealt with there.

## Decision

**The ELT tool is an external producer that lands rows in a staging PostgreSQL schema. Ingestion is not built
in Ash, and staging is not part of the platform. Meltano first; Airbyte is the named fallback.**

### The boundary, precisely

`staging` is an ordinary Postgres schema that the ELT tool owns and Ash does not model. Nothing in it is an
`AshEnterprise.Platform.Resource`. It has no `organization_id`, no owner columns, no policies, no audit.

Promotion out of staging into a platform resource is an **ordinary Ash create or update action**, and that is
the only place ingested data acquires ownership, tenancy, lifecycle and an audit entry. The boundary exists so
that the ELT tool never touches an authorized resource, and therefore never needs an authorization model of
its own — which is the whole selection bar of this group of ADRs, satisfied by refusal rather than by
integration.

### The Ash leverage: `mix meltano.gen.resource`

A new mix task mirroring `lib/mix/tasks/cdm.gen.resource.ex`, which is the precedent for this shape: read a
declared schema, map it to Ash types, write a resource on `AshEnterprise.Platform.Resource`, create or extend
the domain module, register the domain in config. The generator reads the target's declared schema — Singer
`SCHEMA` messages, or the landed staging table via `pg_attribute` — and emits the *promoted* resource, so
ingested data inherits ownership, tenancy and audit exactly as hand-authored data does.

It carries the CDM generator's refusals across unchanged, and they are the important part:

* **Ownership is never guessed.** `--ownership` is required, exactly as it is for a plain CDM entity with no
  scraped `dataverse.ownership_type`. A remote system's schema says nothing about who owns a row here.
* **Foreign keys are not invented.** A column that looks like a reference is emitted as a plain `:uuid` with a
  note naming the unresolved target, not a relationship.
* **It does not execute pipelines.** The generator's job is schema mapping. `meltano.yml` is written by hand,
  reviewed in a pull request, and run by Meltano.

## Does it consume ActorContext?

**No — and it must not, which is the point.** Meltano runs as a CLI process with no actor and no request. It
authenticates to Postgres with a database role scoped to the `staging` schema and nothing else.

Because staging carries no policies, there is no second authorization model to keep synchronized with
`AshEnterprise.Security.ActorContext`. The tool is not delegating authorization back to us; it is being kept
outside the boundary where authorization applies. That is a legitimate answer to the selection bar, but only
because the boundary is real — the moment somebody points a Singer target at a platform table directly, this
ADR is void, because the write would bypass policies, the audit log and the tenant discriminator in one step.

**What that costs, stated plainly.** Rows in staging are unauthorized data at rest. Any principal with the
staging database role reads every tenant's inbound records. Multi-tenancy is therefore a *promotion-time*
obligation: the pipeline cannot be trusted to set `organization_id`, so the promotion action sets it from the
pipeline's declared tenant, and **a pipeline that lands two tenants' rows in one staging table is a defect the
platform cannot detect.** There is no verifier for this and it is a review obligation, which is a weakness
worth recording rather than hiding.

Operator access to the tool itself is a separate second surface. Meltano's OSS distribution is a CLI with no
user model — access is filesystem and CI permissions. Airbyte's RBAC and SSO are Enterprise-gated (verified on
their pricing page 2026-08-18), so an Airbyte UI in a multi-tenant deployment either grants every operator
every connection or costs money. That is a real point against the fallback and it is not a licensing detail.

## Consequences

**Made easy.** Pipelines are YAML in git, reviewed in pull requests, diffable — the same discipline `mix
ash.codegen --check` already enforces for schema, applied to ingestion. Adding a source is a `meltano.yml`
entry plus one generator invocation. Promoted resources are indistinguishable from hand-authored ones, so
policies, audit and the admin UI work on ingested data with no extra wiring.

**Made hard.** Singer connector quality is variable and community-maintained. **This is the axis on which
Airbyte genuinely wins**: a broken connector is fixed faster in a 600-connector commercially-backed catalogue
than in a Singer tap whose author moved on. Choosing Meltano is choosing licence and reviewability over
connector responsiveness, and if connector coverage or breakage becomes the operational bottleneck, the
correct response is to switch, not to defend the choice.

Two ingestion styles now exist in one codebase — Meltano for third-party sources, `ash_strangler` (ADR 0008)
for legacy relations already in PostgreSQL — and they are genuinely different problems, but somebody will ask
why once.

**Foreclosed.** Querying the warehouse through Ash; thesis 7 §6 is unchanged. Also foreclosed: treating the
lineage graph as complete, because the tool that moves the data emits nothing (see ADR 0012, which must emit
the ingestion Job event from the wrapper that invokes the pipeline, or emit nothing rather than a graph with a
hole at the point data enters).

### Alternatives rejected

| Option | Why not |
|---|---|
| Build connectors as Ash resources with a custom data layer | The remote schema is not ours to declare, so there is nothing to derive. Connector breakage is upstream's release schedule, which is not a thing an application should be on the hook for. |
| **Airbyte first** | Faster to set up and better at connector breakage. Rejected on licence: ELv2 across platform *and* connectors since July 2025, and RBAC/SSO paywalled — which bites specifically in the multi-tenant case this repository is built for. Named as the fallback rather than dismissed. |
| Land ELT output straight into platform tables | Bypasses policies, audit and the tenant column in one move. The staging boundary is the entire mechanism by which this ADR satisfies the selection bar. |
| **dbt** instead of an ELT tool | Solves the T, not the E or L. Complementary, and orthogonal to this decision. |
| Debezium / CDC in | Right answer for streaming a database we control; wrong shape for SaaS APIs, which is the majority of the inbound problem. |

## Reversal

**To swap Meltano for Airbyte:** delete `meltano.yml` and the `transform/` directory, stand up Airbyte, point
its destination at the same `staging` schema. **Nothing in `lib/` changes** — that is what the staging boundary
buys, and it is the reason the fallback can be named rather than hedged. The generated resources, the
promotion actions and the policies are all downstream of a Postgres schema neither tool is special to. Budget a
day, most of it deployment.

**To abandon the generator but keep the pipelines:** delete `lib/mix/tasks/meltano.gen.resource.ex`. Promoted
resources are ordinary files already written to disk with no runtime dependency on the task; you lose the
ability to scaffold *new* ones. Under an hour.

**To abandon external ingestion entirely:** delete `meltano.yml`, drop the `staging` schema, delete the
generator task, and delete the promoted resources and their migrations. The rest of the application has no
dependency on any of it. The expensive part is not the deletion, it is that ADR 0012 and ADR 0013 both lose
their producer and should be reconsidered rather than left in place describing movement that no longer happens.
