# ADR 0013 — OpenMetadata as the catalog, populated from codegen

- **Status:** proposed
- **Date:** 2026-08-18

## Context

Lineage (ADR 0012) answers *how did this get here*. A catalogue answers a different question — *what data do we
have, who owns it, where did the schema come from, and which of it is sensitive* — and the two are routinely
conflated because several products sell both.

This repository is in an unusual position with respect to that question: **it already knows the answers.**
Every resource declares them, because `AshEnterprise.Platform.Resource` makes them mandatory rather than
optional. `ownership:` distinguishes user-owned from business-owned from organization-owned. `tenant?:` says
whether the table carries a tenant discriminator. `cdm_entity:` records that `SystemUser` came from the
Microsoft CDM corpus at a pinned commit (ADR 0001), and `mix cdm.gen.resource` carries each attribute's source
description across as `description`. `api_type:` says whether the resource has a public surface at all.

So the catalogue problem here is not *collecting* metadata. It is publishing metadata that already exists,
into something an auditor or a data steward can search, **without creating a second place where it can be
edited and become wrong.**

### Verified 2026-08-18

| | OpenMetadata | DataHub |
|---|---|---|
| Licence | Apache-2.0 | Apache-2.0 |
| Latest release | `1.13.3-release`, 2026-07-31 | v1.7.0, 2026-08-04 |
| Last commit | 2026-08-18 | 2026-08-18 |
| Governance | **company-controlled** — "OpenMetadata® and the OpenMetadata logo are trademarks of Collate, Inc."; no foundation | company-controlled (DataHub Inc, formerly Acryl Data; rebranded May 2025). *No licence change to the OSS repo found.* |
| Backing services | Postgres ≥15 or MySQL ≥8.0.42, **plus Elasticsearch ≥9.0 or OpenSearch ≥3.0 — required, not optional** | Kafka **+** OpenSearch **+** MySQL, all unconditional in the quickstart profile. Neo4j is opt-in only. |
| Orchestrator | Airflow is the default UI-deployed orchestrator but **is not mandatory** — `metadata ingest -c config.yaml` runs standalone, and Kubernetes uses a native `K8sPipelineClient` | — |
| Connectors | 130+ | — |
| GitHub stars | **14,904** | **12,540** |

Two of those rows correct assumptions that are widely repeated and were both expected to go the other way.

**"One Postgres, optional Elasticsearch" is wrong.** OpenMetadata's minimum-requirements page lists the search
engine alongside the database, not as an option. The honest comparison is **two stateful services against
three including Kafka**, which still favours OpenMetadata but by less than the usual framing suggests.

**DataHub does not obviously have the larger community.** OpenMetadata now has roughly 2,400 *more* GitHub
stars. DataHub advertises "15,000+ Data and AI Practitioners" for its Slack; OpenMetadata advertises "13,500+
Open Source Members" without naming the channel, so the two numbers are not comparable. What survives of the
usual claim is DataHub's Kafka-based streaming metadata model (`MetadataChangeProposal` in,
`MetadataChangeLog` out), which is a real architectural advantage at a scale where metadata changes are
themselves a stream to be subscribed to — and a real cost below it.

## Decision

**OpenMetadata, populated by a push step that runs alongside `mix ash.codegen`. The catalogue is a read-only
mirror of what Ash already declares, and never a second source of truth.**

For a template meant to be cloned and right-sized, the lower operational floor decides it. Somebody adopting
this repository to model thirty resources should not be made to run a Kafka cluster to describe them.

The push writes entities directly over the REST API — `PUT /api/v1/tables`, `/api/v1/databaseSchemas`,
`/api/v1/databases`, where `PUT` is create-or-update — authenticated as a **bot account holding a JWT**
(default `ingestion-bot`, validated against `/api/v1/system/config/jwks`). Verified against the live OpenAPI
spec: no ingestion workflow is required to write an entity, and therefore **no Airflow is required** for this
design at all.

The mapping is mechanical, which is the point:

| Declared here | Published as |
|---|---|
| resource + `postgres do table … end` | Table entity |
| attribute `description` (carried from the CDM by `mix cdm.gen.resource`) | column description |
| `cdm_entity:` | custom property — provenance, with the pinned corpus commit |
| `ownership:` | custom property |
| `tenant?:` | tag |
| `api_type:` present | tag marking a public API surface |

**Nothing is hand-authored in OpenMetadata.** A steward who wants a better description edits the resource,
because that is where the description is derived from — the same rule ADR 0001 applies to CDM provenance and
ADR 0008 applies to lineage. A catalogue you can edit is a catalogue that disagrees with the code.

## Does it consume ActorContext?

**No — and this is the least comfortable answer of the four ADRs in this group, because OpenMetadata does not
merely have its own authorization model, it has one with the opposite semantics.**

OpenMetadata ships a full engine: **Rules** (a resource, an operation, and a SpEL condition such as
`noOwner() && matchAllTags('PersonalData.Personal','Tier.Tier1')`, with an **Allow or Deny effect**) composed
into **Policies**, assigned to **Teams**, bundled into **Roles**. On conflict, **deny wins**.

That is a direct contradiction of [thesis 3](../manifesto/03-authorization-is-data.md), which is built on
Dataverse's rule that "all privilege grants are accumulative with the greatest amount of access prevailing" —
a pure union with no deny rules, which is why `forbid_if` is forbidden for row access in this codebase. A model
where deny beats allow is precedence-dependent by construction. Mirroring our grants into it would not be
translation; it would be reimplementation in a system with different resolution rules.

**So no attempt is made to mirror roles, and that is a decision rather than an omission.** Business units,
depth, sharing and hierarchy security are not expressible there. A partial mirror is the dangerous outcome: a
security control that *looks* enforced, is inspected by an auditor as though it were, and is not.

OpenMetadata therefore gets exactly two levels of access — a catalogue reader, and the ingestion bot — and who
may be a reader is settled at the edge by SSO (Google, Okta, Azure, Auth0, Cognito, OneLogin, Keycloak, custom
OIDC, and SAML on a separate page, all verified) rather than inside the domain model. *SCIM provisioning is
**unverified**: the roadmap issue is closed as done but no documentation page exists, so it should not be
relied on.*

**What that costs, named plainly:** the catalogue **cannot be shown to customers**. A tenant-scoped data
catalogue — where each customer sees only their own datasets — is not achievable this way, and building it
would mean maintaining exactly the second security model this architecture refuses to keep. The catalogue is
an internal tool for stewards and auditors. If it ever needs to face tenants, this ADR is the wrong one and
should be superseded rather than extended.

## Consequences

**Made easy.** The catalogue cannot drift by hand, because nothing is entered by hand. Ownership and provenance
are already declared, so the columns an auditor asks about are populated on day one rather than after a
metadata-entry project. Adding a resource updates the catalogue as a consequence of running codegen, which is
[thesis 4](../manifesto/04-batteries-are-inherited.md)'s measure exactly: forgetting requires effort.

**Made hard.**

*The silent-staleness failure mode is the real risk, and it is worse than having no catalogue.* A push step
that fails quietly leaves a catalogue that is confidently wrong — the same objection ADR 0008 raises against a
lineage diagram that omits edges it could not resolve. Three things address it, and the third is the one this
repository has already learned:

1. The push writes a `catalogSyncedAt` custom property carrying the git SHA of the resource snapshot set.
2. CI extends the `mix ash.codegen --check` gate to fail when the SHA recorded in OpenMetadata does not match
   `HEAD`.
3. **"Could not reach the catalogue" and "the catalogue is stale" report differently.** This is the same
   distinction `.claude/hooks/check-ash-codegen.sh` already draws between drift and a check that could not run
   — a non-zero exit for an unrelated reason is not evidence of drift, and treating it as such produces
   confident wrong action. Unreachable OpenMetadata means the catalogue state is *unknown*, and a step that
   collapses the two states is the defect this whole mitigation exists to prevent.

*Governance is company-controlled.* Apache-2.0 means a fork is possible, which bounds the risk without
eliminating it; there is no foundation to appeal to over a licence or roadmap change. The same is true of
DataHub, so it is not a differentiator — but it belongs in the record.

*The search engine is a real operational cost.* Elasticsearch or OpenSearch is required, and a small
deployment pays for a search cluster to catalogue thirty resources. That is the single strongest argument for
deferring adoption until the resource count justifies it.

*Collate gates the commercial layer* — AskCollate, AI agents for auto-documentation and classification, reverse
metadata write-back, service insights. None of it is needed here, and none of it is load-bearing for this
design, but the line is worth knowing before somebody plans around a feature on the wrong side of it.

**Foreclosed.** A tenant-facing catalogue, per the section above. Also foreclosed by intent: the catalogue as a
source of truth. It is a projection, and anything that would require editing it is a request to change a
resource.

## Reversal

**To swap OpenMetadata for DataHub:** rewrite the push target. Both accept programmatic metadata writes, so the
extraction half — walking `Ash.Domain.Info.resources/1` and reading the `platform` DSL section — is unchanged;
the emitter is not. DataHub's model is `MetadataChangeProposal` events onto Kafka rather than `PUT` to a REST
path, so this is a genuine rewrite of one module plus the arrival of a broker. **Two to three days, most of it
infrastructure.** It becomes the right move if metadata changes need to be *subscribed to* rather than
queried.

**To abandon the catalogue entirely:** delete `lib/mix/tasks/ash_enterprise.catalog.push.ex`, remove the CI
step and the config block holding the OpenMetadata base URL and bot token, and stop running the service. **No
resource changes** — the metadata being published is declared for this application's own purposes and would
still be there with nothing reading it. Under an hour, and the only loss is the search surface.

**To keep the catalogue but abandon push-on-codegen:** point OpenMetadata's own PostgreSQL connector at the
database and let it introspect on a schedule. Cheaper to set up and strictly worse: it recovers table and
column structure and **loses `ownership:`, `cdm_entity:` and `tenant?:` entirely**, because those are Ash
declarations with no representation in the physical schema. That is the trade this ADR exists to refuse, and
it is recorded here as the exit somebody will be tempted by rather than as a recommendation.
