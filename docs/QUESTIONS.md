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
**17 of 54** enterprise questions have a shipped answer.

✅ Shipped 17 · 🟡 Partial 14 · 🔵 Planned 8 · ⚪ Open 15
<!-- roadmap:scoreboard:end -->

<!-- roadmap:sections:start -->
| Section | Shipped | Partial | Planned | Open |
|---|---|---|---|---|
| Who are you, and what may you do? | 4 | 2 | 0 | 4 |
| What happened, and can you prove it? | 8 | 1 | 0 | 2 |
| Whose data is it? | 2 | 1 | 0 | 3 |
| Where does data come from, and where does it go? | 0 | 0 | 6 | 2 |
| How does it change, and keep running? | 3 | 7 | 2 | 1 |
| Can you prove it, continuously? | 0 | 3 | 0 | 3 |
<!-- roadmap:sections:end -->

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
| 29 | How do enterprise customers bring their own identity provider? | Open. AshAuthentication ships password, magic link, API key and OAuth2, and no SAML — which is still the format most enterprise IdPs lead with in a procurement conversation. OIDC is reachable through the existing OAuth2 strategy; SAML would need a new one. | ⚪ Open | — |
| 30 | How do accounts appear and disappear when someone joins or leaves? | Open. Users are created by registration and deactivated by a lifecycle transition; nothing consumes SCIM, so a customer removing someone from their directory does not remove them here. | ⚪ Open | — |
| 31 | What second factor is required, and how are sessions bounded? | Open. Sessions are AshAuthentication's, with no MFA enforcement, no step-up for privileged actions and no configurable session lifetime. WebAuthn was named as a gap in thesis 7 and still is. | ⚪ Open | — |
| 32 | Who may act as someone else, and is that recorded differently from acting as yourself? | Partial. Acting on someone else's behalf is now represented end to end: the record's `created_on_behalf_by_id` names the operator while `created_by_id` names the customer, and every audit event carries `impersonator_id`. What is missing is the gate — nothing yet decides who may impersonate whom, or records a session with a stated reason. | 🟡 Partial | `test/ash_enterprise/audit/impersonation_test.exs` |

### What happened, and can you prove it?

| # | Question | Our answer | Status | Proven by |
|---|---|---|---|---|
| 7 | Is every change recorded, including who and from where? | `AshEvents` writes a central append-only log on every create, update and destroy — inherited from the base resource, not wired per resource, so a new table cannot quietly have no history. | ✅ Shipped | `lib/ash_enterprise/audit/event_log.ex` |
| 8 | Can you follow one request across the whole system at 3am? | One correlation id per request, stamped into audit metadata and OTel spans, and carried across process boundaries explicitly. | ✅ Shipped | `test/ash_enterprise/platform/correlation_test.exs` |
| 9 | Are illegal state transitions impossible, or merely discouraged? | `ash_state_machine` generates one named action per legal transition from the canonical Dataverse lifecycle. There is no generic `:update` that can set a state. | ✅ Shipped | `test/ash_enterprise/platform/lifecycle_test.exs` |
| 10 | Can a deletion be undone? | `ash_archival` soft delete, inherited. Opting out is an explicit `archival?: false` that a reviewer can grep for. | ✅ Shipped | `lib/ash_enterprise/platform/resource.ex` |
| 11 | Can you rebuild state by replaying the log? | The `AshEvents` replay machinery is wired, but the clear-records step deliberately refuses by default — it is indistinguishable from "delete all business data", so each deployment authorizes it explicitly. | 🟡 Partial | `lib/ash_enterprise/audit/clear_records_for_replay.ex` |
| 33 | Can the audit log be altered after the fact? | Shipped. Two mechanisms with different jobs: a trigger refuses `UPDATE` and `DELETE` outright, and every event carries a SHA-256 chained to the previous one, so an operator privileged enough to drop the trigger still cannot make an edit look untouched. `mix ash_enterprise.audit.verify` walks the chains; the suite proves it by tampering. | ✅ Shipped | `test/ash_enterprise/audit/chain_test.exs` |
| 34 | Can a customer see their own audit trail, and only theirs? | Shipped. The log is attribute-multitenant on an `organization_id` the chain trigger derives from stamped metadata, so a tenant-scoped read is filtered by the data layer rather than by a policy written specially for the audit log. Depth answers how much of a tenant you see; tenancy answers which tenant. | ✅ Shipped | `test/ash_enterprise/audit/tenant_isolation_test.exs` |
| 35 | Can an auditor be handed a window of evidence without engineering help? | Shipped. `mix ash_enterprise.audit.export --from --to [--tenant]` writes CSV in chain order, including `sequence`, `previous_hash` and `hash` so the recipient can re-verify it rather than take it on trust. It reads through the ordinary action layer, so an export is exactly as wide as its requester's authorization. | ✅ Shipped | `lib/ash_enterprise/audit/export.ex` |
| 36 | How long is evidence kept, and where does it live after ninety days? | Open. Nothing expires, nothing is partitioned, and nothing moves to cold storage — so a twelve-month SOC 2 observation window is retained by accident rather than by policy. Made sharper by the immutability trigger, which now actively refuses the `DELETE` a retention job would need. | ⚪ Open | [ADR 0024](adr/0024-audit-retention-and-erasure.md) |
| 37 | Are role and permission changes attributable to a person? | Shipped. Role assignments are ordinary audited resources, so granting one produces an event naming the grantor, the grantee and the correlation id of the request — and the record itself now carries `created_by_id`, which nothing populated before. | ✅ Shipped | `test/ash_enterprise/audit/impersonation_test.exs` |
| 38 | Where do logs go to be reviewed, and what raises an alarm? | Open. Everything is queryable in Postgres and nothing streams anywhere. An auditor asks for evidence that logs are *reviewed*, not merely kept, and there is none: no SIEM export, no anomaly rules, no record of a human having looked. | ⚪ Open | [ADR 0025](adr/0025-log-shipping-and-review.md) |

### Whose data is it?

| # | Question | Our answer | Status | Proven by |
|---|---|---|---|---|
| 12 | How are tenants separated? | Attribute multitenancy on `organization_id`, inherited by every resource — never schema-per-tenant, and never per-department. | ✅ Shipped | `test/ash_enterprise/security/tenant_resolution_test.exs` |
| 13 | Does tenant isolation hold even when authorization is wrong? | Yes, and it is asserted as a separate property: the conformance suite checks isolation independently of every grant path. | ✅ Shipped | `test/ash_enterprise/security/conformance_test.exs` |
| 14 | Can you erase a person on request? | No. `ash_archival` is soft delete only — there is no purge schedule, no anonymization pipeline, and an append-only audit log is exactly what a right-to-erasure request runs into. | ⚪ Open | — |
| 15 | Where does the data physically live? | Undecided. Attribute multitenancy makes residency a deployment question rather than a schema one, which is a deferral, not an answer. | ⚪ Open | — |
| 39 | What crosses the tenant boundary, and to whom? | Open. There is no data inventory, no classification, and no published sub-processor list — which is the first artefact a security questionnaire asks for and the one that has to be current rather than merely written once. | ⚪ Open | — |
| 40 | What does an AI model see, and can a customer opt out? | Partial. Thesis 5 settles the authorization half — an agent is an actor with an actor's permissions, and `ash_ai` tools are declarations that existing actions may be invoked, so a model reaches nothing its user could not. What is absent is the governance half: no prompt or response logging, no per-tenant opt-out, no disclosure of which model or vendor saw what. | 🟡 Partial | [ADR 0026](adr/0026-ai-governance-is-disclosure.md) |

### Where does data come from, and where does it go?

| # | Question | Our answer | Status | Proven by |
|---|---|---|---|---|
| 16 | How does data get in from systems you do not own? | Meltano lands rows in a staging schema as an external producer; a generator turns the declared target schema into an ordinary platform resource, so ingested data inherits ownership, tenancy and audit. | 🔵 Planned | [ADR 0010](adr/0010-meltano-for-ingestion.md) |
| 17 | How do you integrate N SaaS systems without writing N×M integrations? | One contract per category rather than one per (your app × their API). Nango holds the provider edge — OAuth, token refresh, the proxy — and the sync logic stays here as Ash actions over Oban, so a policy gates which actor may trigger a sync and the ordinary audit log records it. Nango's free self-hosted edition gates syncs and webhooks, which is why the design is split that way rather than generated wholesale. | 🔵 Planned | [ADR 0011](adr/0011-nango-as-integration-hub.md) |
| 18 | Can you trace a value back to the system it came from? | OpenLineage events whose run id *is* the correlation id the audit log already carries — lineage as a second consumer of existing telemetry rather than a parallel system. `ash_strangler` already ships the emitter for column-level mappings. Neither Meltano nor Airbyte emits OpenLineage, so the graph has a hole exactly where external data enters, and that is stated rather than drawn over. | 🔵 Planned | [ADR 0012](adr/0012-openlineage-and-marquez.md) |
| 19 | What data do you have, and who owns it? | A catalogue populated from codegen — every resource already declares its CDM provenance, ownership type and tenancy scope, so it is a read-only projection rather than a second source of truth. It is an internal tool only: its own RBAC resolves deny-wins, which is the inverse of this project's model. | 🔵 Planned | [ADR 0013](adr/0013-openmetadata-as-catalog.md) |
| 20 | How do people get reports out of it? | Superset over views already filtered by the same actor context, so the BI tool's row-level security is a formality rather than a duplicate authorization model. Metabase loses because its RLS is paywalled. | 🔵 Planned | [ADR 0014](adr/0014-superset-over-metabase.md) |
| 21 | The same customer arrived from three systems — which one is real? | Entity resolution as an Ash calculation and change pipeline over the CDM-derived resources, so the golden record inherits ownership, audit and policy instead of living in a second system. | 🔵 Planned | [ADR 0017](adr/0017-entity-resolution-in-ash.md) |
| 41 | How do other systems find out that something happened here? | Open. Events land in the audit log and go nowhere else. There is no outbound webhook, no subscription, and no delivery guarantee for anyone who needs to react to a change rather than poll for it. | ⚪ Open | — |
| 42 | How does a customer get fifty thousand rows in, or out? | Open. JSON:API and GraphQL paginate, and neither is a bulk path. Import exists only as a Meltano-shaped plan; export exists only for the audit log. | ⚪ Open | — |

### How does it change, and keep running?

| # | Question | Our answer | Status | Proven by |
|---|---|---|---|---|
| 22 | How do you move onto this platform from a database you cannot stop? | `ash_strangler` maps a well-modelled resource onto the legacy schema through a closed grammar of typed combinators whose reverses are built rather than guessed, and moves it through four cutover phases without hand-written SQL. 341 tests, including round-trip properties over the legacy value space. **Running here**: `legacy.users` is read through a compatibility view as an ordinary platform resource, a Postgres trigger and listener make that surface live, and the same change is *projected* into a table this application owns -- so there are two live surfaces over the same people, one over the view and one over real columns, and the second is audited where the first structurally cannot be. Still partial, and deliberately: this is not a cutover. The legacy database remains the system of record, and the mapping is not invertible in two documented places (`full_name` cannot be split back into first and last; `company_id` is unmapped), which is exactly what a true cutover would have to resolve. | 🟡 Partial | [ADR 0031](adr/0031-the-legacy-estate-is-projected-not-cut-over.md) |
| 23 | How do the processes people actually follow get modelled? | `ash_bpmn` compiles a BPMN document into an immutable versioned graph and executes it with a token interpreter over Postgres and Oban, with an embedded designer. Gateway conditions are FEEL, the DMN expression language -- the hand-written expression evaluator it replaced is deleted. **Running here**: the six resources sit on the platform base resource, so a process instance is an ordinary owned, tenant-scoped record and the engine's bypass is the first policy in the base's own set. A published baseline, four seeded requests covering every branch of the gateway, and two tenants on different versions of the same key. | ✅ Shipped | [ADR 0009](adr/0009-strangler-and-bpmn-are-first-party.md) |
| 24 | How does an action get a second person's approval before it takes effect? | A change dropped on any action: work item, materialized candidate list, maker-checker exclusion applied by subtraction at candidate resolution rather than as a `forbid_if`, delegation, and escalation timers that get cancelled. **A work item is a platform resource here** -- owned, tenant-scoped and audited -- so who may approve is the same union of grants as who may read, and both the manager and executive approval branches are reachable in the demo. Still partial for one reason: nothing asserts that a user *without* the privilege cannot decide a task, and the positive case passing is not the same evidence. | 🟡 Partial | [ADR 0015](adr/0015-approvals-stay-in-ash.md) |
| 25 | How do API contracts change without breaking the callers you cannot see? | Version deltas declared as data on the resource — one schema, N presentation contracts, no second table or view — with `render`/`parse` invertibility checked at compile time and sunset proposed from real traffic. | 🔵 Planned | [ADR 0019](adr/0019-api-versioning-as-presentation-contract.md) |
| 26 | How do you ship a change to some users first? | A flag is evaluated in-process against the application's own database, with actor, business unit and tenant supplied from the context already computed once per request. Policies are not a substitute — they answer *may you*, not *is this on*, and conflating them produces a `beta_user` role you then have to revoke from everyone. | 🔵 Planned | [ADR 0016](adr/0016-unleash-for-feature-flags.md) |
| 27 | How does the schema itself evolve without drifting from the model? | Migrations are derived as a diff against committed resource snapshots, and the diff is a CI gate — so a resource change without a migration fails the build rather than surfacing at deploy time. | ✅ Shipped | `priv/resource_snapshots/` |
| 28 | Can you tell what is happening in production? | Correlation ids and Ash tracing are wired — `OpentelemetryAsh` is registered as the `Ash.Tracer`, so every action, query and calculation becomes a span with no per-resource wiring. Two things are not: `OpentelemetryPhoenix.setup/1` and `OpentelemetryEcto.setup/1` are never called, so those two declared dependencies emit nothing, and the OTLP endpoint the config comment says lives in `runtime.exs` is not there. The backend is now named; the bridge is still thin. | 🟡 Partial | [ADR 0018](adr/0018-grafana-lgtm-observability-backend.md) |
| 43 | Can a deploy happen without downtime, and can a migration be reversed? | Partial. Every generated migration has a `down`, and `ash_strangler`'s four-phase cutover is built precisely so a legacy migration can be reversed at any phase. What is untested is the app's own rolling deploy: nothing proves an old and a new node can serve the same schema at once, which is the property zero-downtime actually needs. | 🟡 Partial | — |
| 44 | Does it still work for a customer with fifty thousand of something? | Open. No load test, no query budget, and no pagination requirement on read actions — the audit export is the only place in the codebase that streams rather than loads. A reference architecture that has never met a large tenant is making an untested claim. | ⚪ Open | — |
| 45 | Can a customer change how it behaves without a deploy? | Partial, and less partial than it was. A tenant can fork a process or a decision, edit it in the browser and publish it as its own version, with no binding row meaning 'follow the platform baseline' -- so changing behaviour is data, and reverting is deleting a row. Drift from a newer baseline is reported, never merged. What is still a deploy: adding an attribute is a resource change and a migration, and a decision cannot be tried against sample inputs before it is published. | 🟡 Partial | [ADR 0029](adr/0029-process-configuration-is-tenant-data.md) |
| 52 | How are business rules expressed, versioned, and changed without a deploy? | As DMN decisions -- decision tables and literal expressions -- held as versioned, tenant-scoped Ash resources by `ash_decisions` and evaluated by a native Elixir DMN engine measured at 3,414 of 3,495 nodes against the official DMN TCK. Every evaluation records which version decided and what it saw. Partial: the resources and the engine are here, the authoring UI is not. | 🟡 Partial | `test/ash_enterprise/bpmn/adoption_test.exs` |
| 53 | How are business rules expressed, versioned and changed without a deploy? | As DMN, in `ash_decisions`. A decision is a DMN document -- the single artifact, with no second copy of the rules in a table to drift from it -- versioned and immutable on publish, edited in dmn-js, and evaluated either by a business rule task inside a process or by trigger routing deciding which process to start. The engine is adopted rather than written and measured at 97.68% of the official DMN TCK. `OUTPUT ORDER` and `RULE ORDER` are refused at compile time because both make document order semantically significant, which is the same order-dependence the authorization model rejects. What is missing is the proof: publish-time overlap and completeness analysis is designed and unbuilt, so a table with a gap or an overlap publishes without complaint. | 🟡 Partial | [ADR 0028](adr/0028-decisions-are-dmn.md) |
| 54 | Can a UI built on the new model be driven by a database the old application still owns? | Yes, and it is demonstrated rather than asserted: `INSERT INTO legacy.users` in `psql` reaches a surface generated from `AshEnterprise.Accounts.ProjectedUser` -- an Ash-owned table with real columns -- without a reload and without anything in that surface knowing a legacy database exists. The chain is an `AFTER` trigger, `pg_notify` on commit, a listener that re-reads through Ash so the mapped values apply, a notifier that upserts through an ordinary Ash action, and `Ash.Notifier.PubSub`. What it costs: the projection is eventually consistent, and `projected_at` is a column so the lag is on screen rather than hidden. A row that fails to project is silently absent until the backfill is re-run -- there is no retry, and the reconciliation job that would close that gap is not built. | ✅ Shipped | [ADR 0031](adr/0031-the-legacy-estate-is-projected-not-cut-over.md) |

### Can you prove it, continuously?

| # | Question | Our answer | Status | Proven by |
|---|---|---|---|---|
| 46 | Which named controls does any of this actually satisfy? | Partial. `docs/COMPLIANCE.md` maps SOC 2, ISO 27001 and GDPR controls to the questions above and through them to the test that proves each — generated from the same ledger, so it cannot drift. It covers technical prerequisites only: certification also needs policy, process and an auditor, and the document says so first rather than last. | 🟡 Partial | `docs/controls.json` |
| 47 | What is promised about uptime, and what happens when it is missed? | Open. No SLO, no error budget, no status page. Telemetry exists and nothing is expressed as a target, so there is nothing for an incident to be measured against. | ⚪ Open | — |
| 48 | How quickly can you come back from losing the database? | Open. Backups are whatever the deployment provides; nothing here tests a restore, and an untested restore is a belief rather than a control. No RPO or RTO is committed to. | ⚪ Open | — |
| 49 | When something breaks at three in the morning, what happens? | Open. Alerts go nowhere, no rota exists, and no runbook says who tells the customer. The correlation id makes the investigation possible; nothing makes it start. | ⚪ Open | — |
| 50 | What is in the build, and can you prove nothing else is? | Partial. CI runs `mix hex.audit` for retired and vulnerable packages and `mix sobelow` for web vulnerabilities, and `mix.lock` pins everything transitively. There is no SBOM, no signed build, and no provenance attestation — so the dependency set is checked but not attested. | 🟡 Partial | `.github/workflows/ci.yml` |
| 51 | Can you show a control operated continuously for twelve months? | Partial. This is the question the rest of the section is really asking. What exists: an unbroken, verifiable hash chain covering every write, exportable per tenant for any window. What does not: a retention policy guaranteeing the window is still there in month twelve, and any evidence that anyone reviewed it. | 🟡 Partial | [ADR 0021](adr/0021-control-mapping-is-generated.md) |
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
