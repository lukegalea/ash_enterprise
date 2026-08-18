# Ash Enterprise

A reference Elixir/Ash application: a base template for enterprise software —
ERP, workflow management, line-of-business systems — with an opinionated answer
for every cross-cutting concern, and a repeatable process for growing the domain
model over time.

**The argument is in [`docs/manifesto/`](docs/manifesto/00-index.md). The code is
the evidence.** Several things here look unusual on purpose; the reasoning is
written down.

## The thesis

> The cross-cutting concerns of enterprise software are declarable. Declare them
> once, derive them everywhere, and what is left over is the actual business.

Enterprise software is not hard because any one feature is hard. It is hard
because ownership, hierarchical access control, audit, versioning, multitenancy,
lifecycle and integration surfaces cross-cut *every* entity. Written per feature,
they decay. Declared once, they cannot.

## Every enterprise application answers the same questions

Not the same features — the same *questions*. Who owns this record; who may see it; what happened to
it and can you prove it; whose tenant is it; where did the data come from; how does the contract change
without breaking the callers you cannot see. Most systems answer them one feature at a time, and find
out in month nine which answers disagree.

This is the ledger. ✅ means working code plus a test that would fail if it regressed; 🟡 means it
works with a limitation stated in the answer; 🔵 means a decision is written down and no code exists;
⚪ means a gap with no decision taken.

<!-- roadmap:scoreboard:start -->
**11 of 28** enterprise questions have a shipped answer.

✅ Shipped 11 · 🟡 Partial 6 · 🔵 Planned 8 · ⚪ Open 3
<!-- roadmap:scoreboard:end -->

<details>
<summary><strong>The full ledger — click to expand</strong></summary>

<!-- roadmap:questions-summary:start -->
| # | Question | Our answer | Status |
|---|---|---|---|
| 1 | How do people prove who they are? | Password, magic link, OAuth2/OIDC and API keys via `ash_authentication`. No WebAuthn and no SAML anywhere in the ecosystem — the two gaps most likely to appear in an RFP. | 🟡 Partial |
| 2 | How is "may this actor do this?" decided? | `(role, privilege, depth)` rows evaluated as a pure union of grants — authorization is data, not code. No deny rules, so order cannot matter. | ✅ Shipped |
| 3 | Who owns a record? | Polymorphic user-or-team ownership inherited from the base resource. The Dataverse ownership type per entity is scraped from the corpus, never guessed. | ✅ Shipped |
| 4 | How does where you sit in the org chart change what you can see? | A business-unit tree with a materialized path, plus an optional manager/position hierarchy. Grant depth expands to a subtree once per request, never inside a policy check. | ✅ Shipped |
| 5 | Can one record be shared with someone the rules would not otherwise reach? | An `AccessGrant` row — Dataverse's `PrincipalObjectAccess` — adds rights to one record without widening any role. | ✅ Shipped |
| 6 | Are some columns more sensitive than the rows that contain them? | Not yet. Ash field policies would carry this on the same additive model, and the corpus already has `FieldPermission` and `FieldSecurityProfile` — but no field policy is declared anywhere in `lib/` today. | ⚪ Open |
| 10 | Can a deletion be undone? | `ash_archival` soft delete, inherited. Opting out is an explicit `archival?: false` that a reviewer can grep for. | ✅ Shipped |
| 11 | Can you rebuild state by replaying the log? | The `AshEvents` replay machinery is wired, but the clear-records step deliberately refuses by default — it is indistinguishable from "delete all business data", so each deployment authorizes it explicitly. | 🟡 Partial |
| 7 | Is every change recorded, including who and from where? | `AshEvents` writes a central append-only log on every create, update and destroy — inherited from the base resource, not wired per resource, so a new table cannot quietly have no history. | ✅ Shipped |
| 8 | Can you follow one request across the whole system at 3am? | One correlation id per request, stamped into audit metadata and OTel spans, and carried across process boundaries explicitly. | ✅ Shipped |
| 9 | Are illegal state transitions impossible, or merely discouraged? | `ash_state_machine` generates one named action per legal transition from the canonical Dataverse lifecycle. There is no generic `:update` that can set a state. | ✅ Shipped |
| 12 | How are tenants separated? | Attribute multitenancy on `organization_id`, inherited by every resource — never schema-per-tenant, and never per-department. | ✅ Shipped |
| 13 | Does tenant isolation hold even when authorization is wrong? | Yes, and it is asserted as a separate property: the conformance suite checks isolation independently of every grant path. | ✅ Shipped |
| 14 | Can you erase a person on request? | No. `ash_archival` is soft delete only — there is no purge schedule, no anonymization pipeline, and an append-only audit log is exactly what a right-to-erasure request runs into. | ⚪ Open |
| 15 | Where does the data physically live? | Undecided. Attribute multitenancy makes residency a deployment question rather than a schema one, which is a deferral, not an answer. | ⚪ Open |
| 16 | How does data get in from systems you do not own? | Meltano lands rows in a staging schema as an external producer; a generator turns the declared target schema into an ordinary platform resource, so ingested data inherits ownership, tenancy and audit. | 🔵 Planned |
| 17 | How do you integrate N SaaS systems without writing N×M integrations? | One contract per category rather than one per (your app × their API). Nango holds the provider edge — OAuth, token refresh, the proxy — and the sync logic stays here as Ash actions over Oban, so a policy gates which actor may trigger a sync and the ordinary audit log records it. Nango's free self-hosted edition gates syncs and webhooks, which is why the design is split that way rather than generated wholesale. | 🔵 Planned |
| 18 | Can you trace a value back to the system it came from? | OpenLineage events whose run id *is* the correlation id the audit log already carries — lineage as a second consumer of existing telemetry rather than a parallel system. `ash_strangler` already ships the emitter for column-level mappings. Neither Meltano nor Airbyte emits OpenLineage, so the graph has a hole exactly where external data enters, and that is stated rather than drawn over. | 🔵 Planned |
| 19 | What data do you have, and who owns it? | A catalogue populated from codegen — every resource already declares its CDM provenance, ownership type and tenancy scope, so it is a read-only projection rather than a second source of truth. It is an internal tool only: its own RBAC resolves deny-wins, which is the inverse of this project's model. | 🔵 Planned |
| 20 | How do people get reports out of it? | Superset over views already filtered by the same actor context, so the BI tool's row-level security is a formality rather than a duplicate authorization model. Metabase loses because its RLS is paywalled. | 🔵 Planned |
| 21 | The same customer arrived from three systems — which one is real? | Entity resolution as an Ash calculation and change pipeline over the CDM-derived resources, so the golden record inherits ownership, audit and policy instead of living in a second system. | 🔵 Planned |
| 22 | How do you move onto this platform from a database you cannot stop? | `ash_strangler` maps a well-modelled resource onto the legacy schema through a closed grammar of typed combinators whose reverses are built rather than guessed, and moves it through four cutover phases without hand-written SQL. 341 tests, including round-trip properties over the legacy value space. The package ships; the demo inside this repository does not. | 🟡 Partial |
| 23 | How do the processes people actually follow get modelled? | `ash_bpmn` compiles a BPMN document into an immutable versioned graph and executes it with a token interpreter over Postgres and Oban, with an embedded designer. 176 tests. It is not yet wired in here, and it ships no policies while running `authorize?: false` internally — so adopting it is a precondition, not a formality. | 🟡 Partial |
| 24 | How does an action get a second person's approval before it takes effect? | A change dropped on any action: work item, materialized candidate list, maker-checker exclusion applied by subtraction at candidate resolution rather than as a `forbid_if`, delegation, and escalation timers that actually get cancelled. No external BPMN engine — Camunda 7's community edition reached end of life in October 2025 and Camunda 8 Self-Managed needs a paid production licence, so "adopt an open engine" is largely no longer on the table anyway. | 🟡 Partial |
| 25 | How do API contracts change without breaking the callers you cannot see? | Version deltas declared as data on the resource — one schema, N presentation contracts, no second table or view — with `render`/`parse` invertibility checked at compile time and sunset proposed from real traffic. | 🔵 Planned |
| 26 | How do you ship a change to some users first? | A flag is evaluated in-process against the application's own database, with actor, business unit and tenant supplied from the context already computed once per request. Policies are not a substitute — they answer *may you*, not *is this on*, and conflating them produces a `beta_user` role you then have to revoke from everyone. | 🔵 Planned |
| 27 | How does the schema itself evolve without drifting from the model? | Migrations are derived as a diff against committed resource snapshots, and the diff is a CI gate — so a resource change without a migration fails the build rather than surfacing at deploy time. | ✅ Shipped |
| 28 | Can you tell what is happening in production? | Correlation ids and Ash tracing are wired — `OpentelemetryAsh` is registered as the `Ash.Tracer`, so every action, query and calculation becomes a span with no per-resource wiring. Two things are not: `OpentelemetryPhoenix.setup/1` and `OpentelemetryEcto.setup/1` are never called, so those two declared dependencies emit nothing, and the OTLP endpoint the config comment says lives in `runtime.exs` is not there. The backend is now named; the bridge is still thin. | 🟡 Partial |
<!-- roadmap:questions-summary:end -->

</details>

The long form, with what each answer is proven by, is [`docs/QUESTIONS.md`](docs/QUESTIONS.md). The ⚪
rows are argued at length in [thesis 7](docs/manifesto/07-what-we-do-not-have.md), which is the page to
read before committing to any of this.

## Getting started

```bash
devenv up -d                            # Postgres (with pgvector)
devenv shell -- mix setup               # deps, database, migrations
devenv shell -- mix ash_enterprise.seed # a tenant, a role, a user
devenv shell -- iex-server              # the app
```

Sign in with the credentials the seeder prints, then visit:

| URL | What |
|---|---|
| `/agent` | Helper console — the model proposes, you approve, the app executes |
| `/app/users`, `/app/teams`, `/app/roles`, `/app/business-units` | A2UI surfaces derived from resource metadata |
| `/admin` | Zero-config admin over every resource |
| `/clarity` | ER, class, policy and state-machine diagrams (dev only) |
| `/api/json/swaggerui` · `/gql/playground` | JSON:API + OpenAPI, GraphQL |

## What it looks like

No markup was written for any of this. Every surface here is derived from the
same resource definitions — which is the point: the screenshots are what you get
for declaring a resource, before writing any UI.

**A2UI surfaces.** One page per resource, rendered from resource metadata. The
list, the filter, the pagination and the create form are all derived; the actor
and the tenant are the only things the LiveView supplies, so each surface is
filtered by exactly the policies that guard the API.

What *is* declared is a dozen lines of layout intent per surface — which field is
the title, which is the status badge, what belongs in the metadata grid — because
a derived screen still has to be told what matters. Nothing in that declaration
is styling; A2UI's components carry no spacing or colour props at all, in any
version of the spec. Appearance comes from a CSS custom-property contract that
`assets/css/app.css` maps onto daisyUI's tokens, so these pages follow the same
theme and the same dark-mode toggle as the rest of the app.

![The business-unit surface, showing the materialized-path hierarchy](docs/screenshots/a2ui-business-units.png)

The same generator, three more resources — users, teams and security roles:

| Users | Teams | Roles |
|---|---|---|
| ![](docs/screenshots/a2ui-users.png) | ![](docs/screenshots/a2ui-teams.png) | ![](docs/screenshots/a2ui-roles.png) |

**The helper console.** Ask for an administrative change in plain language. The
model plans and returns a struct; it never holds the mutation, so there is no
tool for a prompt injection to reach.

Here it has interpreted *"Give dana@example.com the Auditor role"*. The names are
resolved **as you**, against records you are allowed to see — so a user you
cannot read comes back as "not found" rather than as a proposal referencing a
record you have no business knowing exists. Authorization is checked before this
card is rendered, so you are never asked to confirm something that will then
fail:

![The helper console, showing a proposed role assignment awaiting approval](docs/screenshots/agent-proposal.png)

Approving executes it *as you*, through the same policies as the admin UI. The
audit row names the human who approved, not the model that suggested:

![The helper console after approval, showing the change was applied](docs/screenshots/agent-approved.png)

Interpreting a request needs a provider key. Everything after it — resolution,
authorization, execution, audit — is ordinary Ash code and does not, which is why
the flow is exercised end to end by the test suite without one.

**AshAdmin.** Every resource, every action, no configuration.

![AshAdmin showing the User resource](docs/screenshots/admin.png)

**GraphQL.** The schema — types, filter inputs, sort inputs, pagination — is
generated from the resources that opt into an `api_type`. Nothing in the list
below was hand-written.

![The GraphQL playground with the schema explorer open](docs/screenshots/graphql-playground.png)

## What is here

**A platform layer.** `AshEnterprise.Platform.Resource` is the base resource
every resource uses. Ownership, provenance, lifecycle, concurrency, tenancy,
audit, soft delete, telemetry and authorization arrive by inheritance — not by
per-resource discipline.

**Authorization as data.** A faithful implementation of the Dataverse security
model: `(role, privilege, depth)` rows evaluated as a **pure union of grants**,
with business-unit hierarchy, per-record sharing, and manager/position hierarchy.
`test/ash_enterprise/security/conformance_test.exs` is the truth table, and it is
the first thing to read when the model surprises you.

**A schema commons.** Entities derived from the Microsoft Common Data Model —
vendored at a pinned commit, resolved offline, committed as flat JSON. 43 CDM
entities plus 18 from the Dataverse table reference. Do not invent your nouns.

**Agents as first-class users.** The same Ash actions and policies back the web
UI, JSON:API, GraphQL and MCP. An LLM tool is a *declaration that an existing
action may be invoked*, not a parallel code path — which is why there is no
agent-specific authorization, and therefore no agent-specific authorization bug.

## Where this is going

The 🔵 rows above, sequenced. Each is an ADR you can read and disagree with rather than a promise, and
each had to clear one bar: **can the tool be handed a thin generated declaration and delegate
authorization back to `ActorContext`, or does it bring its own?** A tool with its own RBAC is a second
copy of the security model to keep synchronized, and synchronization jobs diverge silently in the
permissive direction.

<!-- roadmap:items:start -->
| Priority | Gap | Choice | Status | ADR |
|---|---|---|---|---|
| 1 | Approvals and maker-checker | ash_bpmn — no external engine | 🟡 Partial | [ADR 0015](docs/adr/0015-approvals-stay-in-ash.md) |
| 1 | Data ingestion | Meltano (MIT); Airbyte as the fallback | 🔵 Planned | [ADR 0010](docs/adr/0010-meltano-for-ingestion.md) |
| 1 | Integration hub — avoiding M×N | Nango for the provider edge only | 🔵 Planned | [ADR 0011](docs/adr/0011-nango-as-integration-hub.md) |
| 1 | Legacy migration and process modelling as platform extensions | ash_strangler + ash_bpmn, first-party | 🟡 Partial | [ADR 0009](docs/adr/0009-strangler-and-bpmn-are-first-party.md) |
| 1 | Lineage and provenance | OpenLineage + Marquez | 🔵 Planned | [ADR 0012](docs/adr/0012-openlineage-and-marquez.md) |
| 2 | API versioning and deprecation | ash_api_versioning | 🔵 Planned | [ADR 0019](docs/adr/0019-api-versioning-as-presentation-contract.md) |
| 2 | Data catalog and governance | OpenMetadata (DataHub is the closer call it looks) | 🔵 Planned | [ADR 0013](docs/adr/0013-openmetadata-as-catalog.md) |
| 2 | Reporting and embedded analytics | Apache Superset over Metabase | 🔵 Planned | [ADR 0014](docs/adr/0014-superset-over-metabase.md) |
| 3 | Feature flags and progressive delivery | FunWithFlags (Unleash rejected) | 🔵 Planned | [ADR 0016](docs/adr/0016-unleash-for-feature-flags.md) |
| 3 | Observability backend | Grafana LGTM | 🔵 Planned | [ADR 0018](docs/adr/0018-grafana-lgtm-observability-backend.md) |
| 4 | Master data and entity resolution | In-Ash resolution over CDM resources | 🔵 Planned | [ADR 0017](docs/adr/0017-entity-resolution-in-ash.md) |
<!-- roadmap:items:end -->

Two strong products lose on that bar outright. **Metabase**: row-level security sits behind the paid
tier even when self-hosted, so adopting it would put the authorization thesis behind a paywall.
**Camunda and Flowable**: a workflow engine is a second identity and assignment model, and it expresses
maker-checker as a deny rule — which non-negotiable 2 forbids.

Two expected answers were reversed by checking them, and both reversals are in the ADRs rather than
quietly dropped. Unleash lost to `FunWithFlags` once its Elixir SDK turned out to draw ~151 downloads a
month against ~1M, and the end-of-life everyone cites attaches to Edge OSS rather than the server. And
the catalogue choice is far closer than it looks: OpenMetadata needs Elasticsearch as well as Postgres,
its OpenLineage ingest is a Kafka consumer rather than an HTTP endpoint, and it has *more* GitHub stars
than DataHub — so the cheap upgrade path from Marquez is DataHub, not OpenMetadata. ADRs 0012 and 0013
do not compose as neatly as the pairing suggests, and both say so.

The reasoning, the sequencing and what stays deliberately open is [`docs/ROADMAP.md`](docs/ROADMAP.md).

## Non-negotiables

1. Every resource uses `AshEnterprise.Platform.Resource`. Opting out is explicit
   and greppable, never silent.
2. **Never use `forbid_if` for row access.** The model is a pure union; one
   `forbid_if` reintroduces order-dependence.
3. **Policy checks never query.** Everything is precomputed once per request into
   `ActorContext`. A check that queries is a bug, not a slow path.
4. Run `mix ash.codegen` after changing a resource. Drift is a CI failure.
5. Never edit `priv/cdm/schemaDocuments/` — vendored CC-BY-4.0 content.
6. **An external tool consumes `ActorContext`; it never keeps its own copy.** A
   service with its own RBAC, tenancy or audit trail is a second security model
   to synchronize, and synchronization diverges silently in the permissive
   direction. Removing such a service must degrade a feature, never break the app.

## Documentation

| Where | What |
|---|---|
| [`docs/QUESTIONS.md`](docs/QUESTIONS.md) | **The ledger** — every question, our answer, and what proves it |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | Where the gaps go, in what order, and what each choice beat |
| [`docs/HANDOFF.md`](docs/HANDOFF.md) | **Start here in a new session** — current state, and findings that cost time to discover |
| [`docs/manifesto/`](docs/manifesto/00-index.md) | The seven theses, including [what we do not have](docs/manifesto/07-what-we-do-not-have.md) |
| [`docs/adr/`](docs/adr/README.md) | Decision records, with the reversal path for each |
| [`docs/plans/`](docs/plans/) | Specifications: strangler-fig migrations, process modelling, API versioning |
| [`docs/roadmap.json`](docs/roadmap.json) | The source every status table above is generated from |
| `AGENTS.md` | Generated from dependency usage rules — do not edit the generated sections |
| `.claude/skills/` | Task-specific guidance for AI agents |

## Honest limits

Read [thesis 7](docs/manifesto/07-what-we-do-not-have.md) before committing to
this stack. The ⚪ rows above are the short version: no WebAuthn or SAML, no
column-level security actually declared, no retention or erasure story for an
append-only audit log inherited by every resource, no content i18n, and no
Dialyzer certainty against Spark-generated code. Each is named rather than
glossed, and the last two paragraphs of thesis 7 explain why naming them is the
only commitment worth making about gaps.

One of those needs saying plainly here: **thesis 4 currently claims field
policies that `lib/` does not contain.** That claim is being corrected rather
than quietly implemented — which is the whole point of keeping a ledger.

## Licence

MIT — see [`LICENSE`](LICENSE). Two vendored corpora are excluded and carry their
own terms: `priv/cdm/schemaDocuments/` is Microsoft's Common Data Model under
CC-BY-4.0, and `priv/cdm/resolved/dataverse_*.json` derives from Microsoft's
Dataverse table reference. Attribution is required for both; see
[`priv/cdm/ATTRIBUTION.md`](priv/cdm/ATTRIBUTION.md).

This is a template, not a product. Clone it, delete what you do not need, and
keep the shape.
