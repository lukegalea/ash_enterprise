# Roadmap

> Where the ⚪ and 🔵 rows of [the checklist](QUESTIONS.md) go, in what order, and why each choice
> beat the alternative.

This repository proves one half of an enterprise application well: identity, authorization, ownership,
hierarchy, audit, lifecycle, tenancy, and the surfaces derived from all of it. It is close to silent on
the other half — **where data comes from, where it goes, how it is traced, how it is integrated, and
how its contracts change.** [`docs/HANDOFF.md`](HANDOFF.md) ends at "what is genuinely not done";
[thesis 7](manifesto/07-what-we-do-not-have.md) names the ecosystem gaps but proposes nothing. This is
the missing forward half.

<!-- roadmap:items:start -->
| Priority | Gap | Choice | Status | ADR |
|---|---|---|---|---|
| 1 | Approvals and maker-checker | ash_bpmn — no external engine | 🟡 Partial | [ADR 0015](adr/0015-approvals-stay-in-ash.md) |
| 1 | Audit retention, partitioning and erasure | Time-partitioned hot/cold split; erasure by crypto-shredding | 🔵 Planned | [ADR 0024](adr/0024-audit-retention-and-erasure.md) |
| 1 | Business rules and decision tables | ash_decisions — DMN, engine adopted not written | 🟡 Partial | [ADR 0028](adr/0028-decisions-are-dmn.md) |
| 1 | Control mapping and evidence | Generated from the ledger; SOC 2, ISO 27001, GDPR | 🟡 Partial | [ADR 0021](adr/0021-control-mapping-is-generated.md) |
| 1 | Data ingestion | Meltano (MIT); Airbyte as the fallback | 🔵 Planned | [ADR 0010](adr/0010-meltano-for-ingestion.md) |
| 1 | Enterprise identity: SAML, OIDC and SCIM | AshAuthentication strategies; SCIM as a resource-backed endpoint | 🔵 Planned | — |
| 1 | Integration hub — avoiding M×N | Nango for the provider edge only | 🔵 Planned | [ADR 0011](adr/0011-nango-as-integration-hub.md) |
| 1 | Legacy migration, process modelling and decisions as platform extensions | ash_strangler + ash_bpmn + ash_decisions, first-party | ✅ Shipped | [ADR 0009](adr/0009-strangler-and-bpmn-are-first-party.md) |
| 1 | Lineage and provenance | OpenLineage + Marquez | 🔵 Planned | [ADR 0012](adr/0012-openlineage-and-marquez.md) |
| 2 | AI governance: what leaves the tenant boundary | Prompt/response logging as audit events; per-tenant opt-out | 🔵 Planned | [ADR 0026](adr/0026-ai-governance-is-disclosure.md) |
| 2 | API versioning and deprecation | ash_api_versioning | 🔵 Planned | [ADR 0019](adr/0019-api-versioning-as-presentation-contract.md) |
| 2 | Break-glass and impersonation control | In-Ash: a session resource with a stated reason | 🟡 Partial | — |
| 2 | Data catalog and governance | OpenMetadata (DataHub is the closer call it looks) | 🔵 Planned | [ADR 0013](adr/0013-openmetadata-as-catalog.md) |
| 2 | Log shipping, review and alerting | Structured export to the customer's SIEM; Grafana for ours | 🔵 Planned | [ADR 0025](adr/0025-log-shipping-and-review.md) |
| 2 | Reporting and embedded analytics | Apache Superset over Metabase | 🔵 Planned | [ADR 0014](adr/0014-superset-over-metabase.md) |
| 2 | SLOs, disaster recovery and incident response | Committed RPO/RTO with a tested restore; error budgets | 🔵 Planned | — |
| 3 | Bulk import and export | Ash bulk actions over a staged upload | 🔵 Planned | — |
| 3 | Data inventory, classification and sub-processors | Derived from resource metadata, not maintained by hand | 🔵 Planned | — |
| 3 | Feature flags and progressive delivery | FunWithFlags (Unleash rejected) | 🔵 Planned | [ADR 0016](adr/0016-unleash-for-feature-flags.md) |
| 3 | Observability backend | Grafana LGTM | 🔵 Planned | [ADR 0018](adr/0018-grafana-lgtm-observability-backend.md) |
| 3 | Outbound events and subscriptions | An Ash notifier over the existing event log | 🔵 Planned | — |
| 4 | Master data and entity resolution | In-Ash resolution over CDM resources | 🔵 Planned | [ADR 0017](adr/0017-entity-resolution-in-ash.md) |
| 4 | Performance at enterprise data volumes | A seeded large tenant and a query budget | 🔵 Planned | — |
| 4 | SBOM and build provenance | CycloneDX SBOM; attested builds | 🔵 Planned | — |
| 4 | Zero-downtime deploys and reversible migrations | Expand/contract, proven by a two-version test | 🔵 Planned | — |
<!-- roadmap:items:end -->

Generated from [`roadmap.json`](roadmap.json). Edit the JSON, not the table.

---

## The bar every item had to clear

There is exactly one selection rule, and it disqualified several tools that would otherwise have won on
features.

> **An external tool earns a place only if it can be handed a thin, generated declaration and delegate
> authorization back to `AshEnterprise.Security.ActorContext`.**

This is the structural trick `ash_a2ui` already demonstrates in this repository: A2UI carries no
business logic and no authorization of its own — it renders from resource metadata, and Ash supplies
the actor, the tenant and the policy filtering. It is also
[thesis 5](manifesto/05-agents-are-users.md)'s rule restated for a different kind of caller: *an LLM
tool is a declaration that an existing action may be invoked, not a parallel code path* — and so is an
external sync, and so is a BI query.

A tool that brings its own RBAC, its own tenancy model or its own audit trail is a second copy of the
security model to keep synchronized. Every synchronization job diverges eventually, and it diverges
silently in the permissive direction. That is a stricter bar than "does an open-source project exist
for this", and three strong products lose on it specifically:

| Product | Why it loses |
|---|---|
| **Metabase** | Row-level security is behind the paid tier even when self-hosted. Adopting it would put [thesis 3](manifesto/03-authorization-is-data.md) behind a paywall. → [ADR 0014](adr/0014-superset-over-metabase.md) |
| **Camunda / Flowable** | Not a licensing objection — a workflow engine is a second identity, assignment and authorization model, and it expresses maker-checker as a deny rule, which this repository forbids outright. → [ADR 0015](adr/0015-approvals-stay-in-ash.md) |
| **Unleash** | Expected to win, and did not. Targeting means shipping actor attributes to a service keeping its own notion of who they are; its Elixir SDK draws ~151 downloads a month against `FunWithFlags`' ~1M, and a flag check is on a hot path. → [ADR 0016](adr/0016-unleash-for-feature-flags.md) |

Nango is the awkward case: it clears the bar only because the design was inverted after checking it.
Its free self-hosted edition covers auth and proxy but **gates syncs, actions and webhooks**, so
"generate one Ash action per Nango sync" would have put the mechanism behind a paid tier. It is adopted
for the provider edge only, with sync logic staying here as Ash actions over Oban — and with one
load-bearing rule: the Nango connection id is never an action argument, or the policy engine authorizes
the operation while the caller chooses whose credentials to spend. → [ADR 0011](adr/0011-nango-as-integration-hub.md)

### Where the neat story did not survive checking

Four premises this roadmap was drafted on turned out to be wrong, and correcting them is more useful
than the tidier version:

- **Meltano is MIT**, not Apache-2.0. And **Airbyte's connectors moved from MIT to ELv2 in July 2025**,
  so the "source-available platform, open connectors" split no longer holds — the fallback is
  source-available throughout.
- **Neither Meltano nor Airbyte emits OpenLineage.** That leaves a hole in the lineage graph exactly
  where external data enters. [ADR 0008](adr/0008-typed-invertible-legacy-mappings.md)'s own argument
  applies — a diagram that omits edges it could not work out is worse than no diagram, because a reader
  cannot tell "nothing feeds this" from "the generator gave up" — so the hole is drawn as a hole.
- **OpenMetadata requires Elasticsearch or OpenSearch**, not optionally. It is two stateful services,
  not "one Postgres", which was the argument that put it ahead of DataHub.
- **OpenMetadata's OpenLineage ingest is a Kafka/Kinesis consumer, not an HTTP endpoint.** So the cheap
  upgrade from Marquez is **DataHub** — a base-URL change — while OpenMetadata needs a Kafka hop. The
  reversal path out of [ADR 0012](adr/0012-openlineage-and-marquez.md) and the destination chosen in
  [ADR 0013](adr/0013-openmetadata-as-catalog.md) therefore point at different products. Both records
  say so; it is a real tension, not an oversight.

## The extension to the tier model

[Thesis 6](manifesto/06-reversibility.md) tiers *Elixir dependencies* by how much of the codebase may
know about them. Most of this roadmap is a different animal — an **external service behind a network
boundary**, not a `mix.exs` entry. Two rules govern those:

1. The service consumes `ActorContext`, or the views derived from it. It never owns a second copy of
   the authorization model.
2. Removing it degrades a feature. It never breaks the application.

Marquez going down should cost you lineage, not writes.

## Sequencing, and why

**Priority 1 is a chain, not a set.** Ingestion first, because lineage and cataloguing are meaningless
without something producing traceable ingestion events — you cannot trace provenance for data that
arrived by hand. Lineage next, because it is nearly free once ingestion exists: the correlation id is
already threaded through every action by `AshEnterprise.Platform.Correlation`, and `ash_strangler`
already ships an OpenLineage emitter for column-level mappings, so the pattern is proven inside the
family before it is generalized. The integration hub sits alongside rather than after, because it
answers a different question — data you pull versus systems you talk to.

Sharing priority 1 with all of that is the composition already half-built: adopting `ash_strangler` and
`ash_bpmn` here. The three authorization gaps
[ADR 0009](adr/0009-strangler-and-bpmn-are-first-party.md) named in `ash_bpmn` were closed upstream on
2026-08-18 — the engine carries an actor and a tenant through one declared policy bypass, and its
resources can sit on this platform's base resource — so what remains is depending on both packages
here and demonstrating them. That work is first because it is the only item where the claim on the
landing page is ahead of the code, and that is the one kind of debt this repository refuses to carry.

**Priority 2 consumes what priority 1 produces.** A catalog needs something to catalogue; BI needs
something to report on. API versioning sits here rather than lower because it is the item most likely
to be needed *before* it is wanted — the first external consumer of the JSON:API surface is the point
after which changing it becomes expensive.

**Priority 3 and 4 are genuinely deferrable.** Feature flags matter when there are enough users to
stage a rollout to. Entity resolution matters when the same customer has arrived from three systems,
which is a consequence of priority 1 rather than a precondition for it.

## What is not on the roadmap, and stays open

These have no decision, and saying so is the point of
[thesis 7](manifesto/07-what-we-do-not-have.md):

- **WebAuthn / passkeys and SAML 2.0.** The two authentication gaps most likely to appear in an RFP.
  No ecosystem answer exists for either; building one is real work, not a weekend.
- **Retention, purge and right-to-erasure.** The hardest of the open items, because it is in genuine
  tension with [thesis 4](manifesto/04-batteries-are-inherited.md): an append-only audit log inherited
  by every resource is exactly what a GDPR Article 17 request runs into. This needs a design, not a
  tool.
- **Column-level security.** The corpus already models `FieldPermission` and `FieldSecurityProfile`,
  and Ash field policies would carry it on the same additive model — but nothing is declared today, and
  [thesis 4](manifesto/04-batteries-are-inherited.md) currently claims otherwise. That claim is being
  corrected rather than implemented.
- **Content internationalization.** Three competing packages, none adopted. UI strings are covered by
  Gettext; a product name in six languages, per tenant, is not.
- **Data residency.** Attribute multitenancy makes this a deployment question rather than a schema one,
  which defers it rather than answering it.

## How this page stays honest

Every status here and in [the checklist](QUESTIONS.md) comes from [`roadmap.json`](roadmap.json), and
`mix ash_enterprise.roadmap --check` runs in CI beside `mix ash.codegen --check`. Both gates exist for
the same reason: a derived artifact that *can* drift from its source eventually will. A status can
therefore be wrong in one place only by being wrong in all of them — which is easier to notice.
