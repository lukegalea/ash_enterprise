# The enterprise checklist

> Every enterprise application answers the same questions. Most answer them one feature at a time,
> inconsistently, and discover in month nine which ones they got wrong.

This page is the list, and this repository's answer to each. It is the companion to
[the manifesto](manifesto/00-index.md): the manifesto argues *why* the cross-cutting concerns should be
declared once, and this is the ledger of which ones actually are.

Nothing here is aspirational. Every row is one of four states, and the vocabulary is deliberate:

| Status | Means |
|---|---|
| ✅ **Shipped** | Working code, plus a test that would fail if it regressed. The "Proven by" column names it. |
| 🟡 **Partial** | Works, with a limitation stated in the answer itself rather than in a footnote. |
| 🔵 **Planned** | A decision has been taken and written down as an ADR. No code. |
| ⚪ **Open** | Named as a gap. No decision taken. |

A "partial" is not a "shipped" with an asterisk, and a "planned" is not a promise — it is an argument
you can read and disagree with. [Thesis 7](manifesto/07-what-we-do-not-have.md) is the longer form of
every ⚪ row below.

**This table is generated.** The source is [`roadmap.json`](roadmap.json), rendered by
`mix ash_enterprise.roadmap` and checked in CI, so a status cannot be right here and wrong in the
README. Edit the JSON, never the table.

<!-- roadmap:scoreboard:start -->
**11 of 28** enterprise questions have a shipped answer.

✅ Shipped 11 · 🟡 Partial 6 · 🔵 Planned 8 · ⚪ Open 3
<!-- roadmap:scoreboard:end -->

---

<!-- roadmap:questions:start -->
### Who are you, and what may you do?

| # | Question | Our answer | Status | Proven by |
|---|---|---|---|---|
| 1 | How do people prove who they are? | Password, magic link, OAuth2/OIDC and API keys via `ash_authentication`. No WebAuthn and no SAML anywhere in the ecosystem — the two gaps most likely to appear in an RFP. | 🟡 Partial | `test/ash_enterprise/accounts/sign_in_test.exs` |
| 2 | How is "may this actor do this?" decided? | `(role, privilege, depth)` rows evaluated as a pure union of grants — authorization is data, not code. No deny rules, so order cannot matter. | ✅ Shipped | `test/ash_enterprise/security/conformance_test.exs` |
| 3 | Who owns a record? | Polymorphic user-or-team ownership inherited from the base resource. The Dataverse ownership type per entity is scraped from the corpus, never guessed. | ✅ Shipped | `lib/ash_enterprise/platform/system_attributes.ex` |
| 4 | How does where you sit in the org chart change what you can see? | A business-unit tree with a materialized path, plus an optional manager/position hierarchy. Grant depth expands to a subtree once per request, never inside a policy check. | ✅ Shipped | `test/ash_enterprise/security/hierarchy_test.exs` |
| 5 | Can one record be shared with someone the rules would not otherwise reach? | An `AccessGrant` row — Dataverse's `PrincipalObjectAccess` — adds rights to one record without widening any role. | ✅ Shipped | `lib/ash_enterprise/security/checks/shared_with_actor.ex` |
| 6 | Are some columns more sensitive than the rows that contain them? | Not yet. Ash field policies would carry this on the same additive model, and the corpus already has `FieldPermission` and `FieldSecurityProfile` — but no field policy is declared anywhere in `lib/` today. | ⚪ Open | — |

### What happened, and can you prove it?

| # | Question | Our answer | Status | Proven by |
|---|---|---|---|---|
| 7 | Is every change recorded, including who and from where? | `AshEvents` writes a central append-only log on every create, update and destroy — inherited from the base resource, not wired per resource, so a new table cannot quietly have no history. | ✅ Shipped | `lib/ash_enterprise/audit/event_log.ex` |
| 8 | Can you follow one request across the whole system at 3am? | One correlation id per request, stamped into audit metadata and OTel spans, and carried across process boundaries explicitly. | ✅ Shipped | `test/ash_enterprise/platform/correlation_test.exs` |
| 9 | Are illegal state transitions impossible, or merely discouraged? | `ash_state_machine` generates one named action per legal transition from the canonical Dataverse lifecycle. There is no generic `:update` that can set a state. | ✅ Shipped | `test/ash_enterprise/platform/lifecycle_test.exs` |
| 10 | Can a deletion be undone? | `ash_archival` soft delete, inherited. Opting out is an explicit `archival?: false` that a reviewer can grep for. | ✅ Shipped | `lib/ash_enterprise/platform/resource.ex` |
| 11 | Can you rebuild state by replaying the log? | The `AshEvents` replay machinery is wired, but the clear-records step deliberately refuses by default — it is indistinguishable from "delete all business data", so each deployment authorizes it explicitly. | 🟡 Partial | `lib/ash_enterprise/audit/clear_records_for_replay.ex` |

### Whose data is it?

| # | Question | Our answer | Status | Proven by |
|---|---|---|---|---|
| 12 | How are tenants separated? | Attribute multitenancy on `organization_id`, inherited by every resource — never schema-per-tenant, and never per-department. | ✅ Shipped | `test/ash_enterprise/security/tenant_resolution_test.exs` |
| 13 | Does tenant isolation hold even when authorization is wrong? | Yes, and it is asserted as a separate property: the conformance suite checks isolation independently of every grant path. | ✅ Shipped | `test/ash_enterprise/security/conformance_test.exs` |
| 14 | Can you erase a person on request? | No. `ash_archival` is soft delete only — there is no purge schedule, no anonymization pipeline, and an append-only audit log is exactly what a right-to-erasure request runs into. | ⚪ Open | — |
| 15 | Where does the data physically live? | Undecided. Attribute multitenancy makes residency a deployment question rather than a schema one, which is a deferral, not an answer. | ⚪ Open | — |

### Where does data come from, and where does it go?

| # | Question | Our answer | Status | Proven by |
|---|---|---|---|---|
| 16 | How does data get in from systems you do not own? | Meltano lands rows in a staging schema as an external producer; a generator turns the declared target schema into an ordinary platform resource, so ingested data inherits ownership, tenancy and audit. | 🔵 Planned | [ADR 0010](adr/0010-meltano-for-ingestion.md) |
| 17 | How do you integrate N SaaS systems without writing N×M integrations? | One contract per category rather than one per (your app × their API). Nango holds the provider edge — OAuth, token refresh, the proxy — and the sync logic stays here as Ash actions over Oban, so a policy gates which actor may trigger a sync and the ordinary audit log records it. Nango's free self-hosted edition gates syncs and webhooks, which is why the design is split that way rather than generated wholesale. | 🔵 Planned | [ADR 0011](adr/0011-nango-as-integration-hub.md) |
| 18 | Can you trace a value back to the system it came from? | OpenLineage events whose run id *is* the correlation id the audit log already carries — lineage as a second consumer of existing telemetry rather than a parallel system. `ash_strangler` already ships the emitter for column-level mappings. Neither Meltano nor Airbyte emits OpenLineage, so the graph has a hole exactly where external data enters, and that is stated rather than drawn over. | 🔵 Planned | [ADR 0012](adr/0012-openlineage-and-marquez.md) |
| 19 | What data do you have, and who owns it? | A catalogue populated from codegen — every resource already declares its CDM provenance, ownership type and tenancy scope, so it is a read-only projection rather than a second source of truth. It is an internal tool only: its own RBAC resolves deny-wins, which is the inverse of this project's model. | 🔵 Planned | [ADR 0013](adr/0013-openmetadata-as-catalog.md) |
| 20 | How do people get reports out of it? | Superset over views already filtered by the same actor context, so the BI tool's row-level security is a formality rather than a duplicate authorization model. Metabase loses because its RLS is paywalled. | 🔵 Planned | [ADR 0014](adr/0014-superset-over-metabase.md) |
| 21 | The same customer arrived from three systems — which one is real? | Entity resolution as an Ash calculation and change pipeline over the CDM-derived resources, so the golden record inherits ownership, audit and policy instead of living in a second system. | 🔵 Planned | [ADR 0017](adr/0017-entity-resolution-in-ash.md) |

### How does it change, and keep running?

| # | Question | Our answer | Status | Proven by |
|---|---|---|---|---|
| 22 | How do you move onto this platform from a database you cannot stop? | `ash_strangler` maps a well-modelled resource onto the legacy schema through a closed grammar of typed combinators whose reverses are built rather than guessed, and moves it through four cutover phases without hand-written SQL. 341 tests, including round-trip properties over the legacy value space. The package ships; the demo inside this repository does not. | 🟡 Partial | [ADR 0009](adr/0009-strangler-and-bpmn-are-first-party.md) |
| 23 | How do the processes people actually follow get modelled? | `ash_bpmn` compiles a BPMN document into an immutable versioned graph and executes it with a token interpreter over Postgres and Oban, with an embedded designer. 202 tests. The three authorization gaps ADR 0009 named are now closed upstream — the engine carries an actor and a tenant through one named policy bypass, and its resources can sit on this platform's base resource — but it is still not wired in here. | 🟡 Partial | [ADR 0009](adr/0009-strangler-and-bpmn-are-first-party.md) |
| 24 | How does an action get a second person's approval before it takes effect? | A change dropped on any action: work item, materialized candidate list, maker-checker exclusion applied by subtraction at candidate resolution rather than as a `forbid_if`, delegation, and escalation timers that actually get cancelled. No external BPMN engine — Camunda 7's community edition reached end of life in October 2025 and Camunda 8 Self-Managed needs a paid production licence, so "adopt an open engine" is largely no longer on the table anyway. | 🟡 Partial | [ADR 0015](adr/0015-approvals-stay-in-ash.md) |
| 25 | How do API contracts change without breaking the callers you cannot see? | Version deltas declared as data on the resource — one schema, N presentation contracts, no second table or view — with `render`/`parse` invertibility checked at compile time and sunset proposed from real traffic. | 🔵 Planned | [ADR 0019](adr/0019-api-versioning-as-presentation-contract.md) |
| 26 | How do you ship a change to some users first? | A flag is evaluated in-process against the application's own database, with actor, business unit and tenant supplied from the context already computed once per request. Policies are not a substitute — they answer *may you*, not *is this on*, and conflating them produces a `beta_user` role you then have to revoke from everyone. | 🔵 Planned | [ADR 0016](adr/0016-unleash-for-feature-flags.md) |
| 27 | How does the schema itself evolve without drifting from the model? | Migrations are derived as a diff against committed resource snapshots, and the diff is a CI gate — so a resource change without a migration fails the build rather than surfacing at deploy time. | ✅ Shipped | `priv/resource_snapshots/` |
| 28 | Can you tell what is happening in production? | Correlation ids and Ash tracing are wired — `OpentelemetryAsh` is registered as the `Ash.Tracer`, so every action, query and calculation becomes a span with no per-resource wiring. Two things are not: `OpentelemetryPhoenix.setup/1` and `OpentelemetryEcto.setup/1` are never called, so those two declared dependencies emit nothing, and the OTLP endpoint the config comment says lives in `runtime.exs` is not there. The backend is now named; the bridge is still thin. | 🟡 Partial | [ADR 0018](adr/0018-grafana-lgtm-observability-backend.md) |
<!-- roadmap:questions:end -->

---

## What is deliberately not on this list

**"Is it fast?"** — a real question, and not a cross-cutting one. Performance is a property of a
particular query against a particular dataset, and a checklist row claiming it would be meaningless.
The one performance decision that *is* structural is recorded instead as a non-negotiable: a policy
check must never issue a query, which is why `AshEnterprise.Security.ActorContext` resolves the entire
authorization context in about five queries per request rather than one per row.

**"Does it scale?"** — same reason, and it is usually a question about the deployment rather than the
application.

**"Is it tested?"** — the "Proven by" column answers this per row, which is more useful than a
coverage number. The rows without one are the answer to the general question.

## Where to go next

- [The manifesto](manifesto/00-index.md) — the seven theses, and why any of this is shaped the way it is.
- [The roadmap](ROADMAP.md) — the 🔵 rows, sequenced, with the tool comparisons behind each.
- [What we do not have](manifesto/07-what-we-do-not-have.md) — the ⚪ rows, at length, with what each costs.
- [Decision records](adr/README.md) — every fork in the road, and the reversal path out of it.
