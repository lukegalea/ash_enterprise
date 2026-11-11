# Ash Enterprise

A reference Elixir/Ash application: a base template for enterprise software —
ERP, workflow management, line-of-business systems — with an opinionated answer
for every cross-cutting concern, and a repeatable process for growing the domain
model over time.

**The argument is in [`docs/manifesto/`](docs/manifesto/00-index.md). The code is
the evidence.** Several things here look unusual on purpose; the reasoning is
written down.

**The capstone is published:** a vet-clinic demo carved from this tree, showing
agents reading an Ash codebase instead of grepping it —
[`lukegalea/clinic-demo`](https://github.com/lukegalea/clinic-demo), with its
story and evidence index in [`docs/capstone/storyline.md`](docs/capstone/storyline.md).

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

This is the ledger. ✅ means built, covered by a named test, and running in a deployment we operate;
🟡 means it works with a limitation stated in the answer; 🔵 means a decision is written down and no
code exists; ⚪ means a gap with no decision taken.

<!-- roadmap:scoreboard:start -->
**16 of 54** enterprise questions have a shipped answer.

✅ Shipped 16 · 🟡 Partial 23 · 🔵 Planned 5 · ⚪ Open 10
<!-- roadmap:scoreboard:end -->

<!-- roadmap:sections:start -->
| Section | Shipped | Partial | Planned | Open |
|---|---|---|---|---|
| Who are you, and what may you do? | 5 | 4 | 0 | 1 |
| What happened, and can you prove it? | 6 | 3 | 0 | 2 |
| Whose data is it? | 2 | 3 | 0 | 1 |
| Where does data come from, and where does it go? | 1 | 3 | 3 | 2 |
| How does it change, and keep running? | 2 | 7 | 2 | 1 |
| Can you prove it, continuously? | 0 | 3 | 0 | 3 |
<!-- roadmap:sections:end -->

<details>
<summary><strong>The full ledger — click to expand</strong></summary>

<!-- roadmap:questions-summary:start -->
| # | Question | Our answer | Status |
|---|---|---|---|
| 1 | How do people prove who they are? | Password sign-in through `ash_authentication`, with remember-me, email confirmation and password reset: the user resource declares the password and remember-me strategies and no others. Sign-in issues a token that is stored server-side and expires after 8 hours (set explicitly, not the library's 14 days), and changing a password logs the user out everywhere. Five failed sign-ins for one address lock it for 15 minutes, counted atomically in Postgres whether or not the address exists. The API and MCP pipelines read either an ordinary user token or a hashed API key from the bearer header; a key must carry an expiry (90 days at most), can be revoked, and stops working when its owner is deactivated. Not built: magic link (a route and a confirmation hook exist with no strategy behind them), OAuth2/OIDC, SAML and WebAuthn. Bringing an enterprise identity provider is q29. | 🟡 Partial |
| 2 | How is "may this actor do this?" decided? | `(role, privilege, depth)` rows evaluated as a pure union of grants — authorization is data, not code. No deny rules, so order cannot matter. | ✅ Shipped |
| 29 | How do enterprise customers bring their own identity provider? | Not built. `ash_authentication` can federate through its OAuth2 and OIDC strategies, but this host declares none: the user resource has password and remember-me strategies only, no provider is configured and no test signs in through one (checked 2026-11-09). Once wired, Okta, Entra ID or Keycloak would own MFA, password policy and directory truth. SAML is the one protocol that needs a first-party strategy, and it has not been started. | ⚪ Open |
| 3 | Who owns a record? | Polymorphic user-or-team ownership inherited from the base resource. The Dataverse ownership type per entity is scraped from the corpus, never guessed. | ✅ Shipped |
| 30 | How do accounts appear and disappear when someone joins or leaves? | Joining and leaving are in-app actions today, and a directory does not drive them. Joining: registration creates a user with a confirmation email, and the seeder provisions confirmed users. Leaving: the platform lifecycle's `deactivate` action turns a user inactive. A deactivated user with the right password cannot sign in, a bearer token issued earlier stops authenticating and is revoked (reactivating does not revive it), a session subject no longer resolves, a password reset finds nobody inactive, an API key follows its owner, and the user is no longer a member of the tenant, so it loses its actions and its rows. Role grants can carry `valid_until` and are gone at that instant. What is missing: no directory is wired in, since there is no SCIM endpoint and `ash_scim` is not a dependency, so departure still depends on someone here being told. | 🟡 Partial |
| 31 | What second factor is required, and how are sessions bounded? | Sessions are bounded; a second factor is not built. The session token lives 8 hours, set explicitly (`Accounts.TokenPolicy`, host-configurable, a malformed setting raises rather than defaulting), is stored server-side so it can be revoked, and is revoked on deactivation and on a password change. Five failed sign-ins lock an identity for 15 minutes. The browser session cookie still sets no max age. No in-app strategy requires a second factor: the user resource declares password and remember-me and no TOTP or WebAuthn. With enterprise SSO the second factor, step-up and session lifetime would be the provider's, once q29 is built. | 🟡 Partial |
| 32 | Who may act as someone else, and is that recorded differently from acting as yourself? | Acting as someone else is gated, recorded and expiring. The record's `created_on_behalf_by_id` names the operator while `created_by_id` names the customer, and every audit event carries `impersonator_id`. A break-glass session names the operator, the person acted as, a written reason of at least 10 characters, a named approver and an expiry (240 minutes at most, host-configurable). Opening one is a request; it is live only after the named approver approves it, a separate audited act by an active person who is neither the operator nor the subject. Opening and approving need a grant and a human actor, never a system actor or an impersonating one. The session ends at its expiry instant, when ended, or when the operator or subject is deactivated. Not built: telling the account owner when a session opens. | ✅ Shipped |
| 4 | How does where you sit in the org chart change what you can see? | A business-unit tree with a materialized path, plus an optional manager/position hierarchy. Grant depth expands to a subtree once per request, never inside a policy check. | ✅ Shipped |
| 5 | Can one record be shared with someone the rules would not otherwise reach? | An `AccessGrant` row — Dataverse's `PrincipalObjectAccess` — adds rights to one record without widening any role. | ✅ Shipped |
| 6 | Are some columns more sensitive than the rows that contain them? | One resource, not the platform. `AshEnterprise.Integration.LinkedAccount` declares a field policy that hides `connection_id` from every read grant, and the integration tenant-isolation tests exercise it. No field policy sits on the base resource, and no CDM resource uses the corpus's `FieldPermission` or `FieldSecurityProfile` yet, so 'some columns are more sensitive than their rows' is answered for one column and by hand. The model would carry the rest on the same additive footing. | 🟡 Partial |
| 10 | Can a deletion be undone? | A destroy archives the row instead of deleting it: `ash_archival` soft delete, inherited from the base resource, with an explicit `archival?: false` that a reviewer can grep for. Partial because reversal is not a feature: there is no restore action anywhere in `lib/`, so undoing a deletion is an operator's database operation, and I found no test that asserts an archived row is retained and can be brought back. | 🟡 Partial |
| 11 | Can you rebuild state by replaying the log? | The `AshEvents` replay machinery is wired, but the clear-records step deliberately refuses by default — it is indistinguishable from "delete all business data", so each deployment authorizes it explicitly. | 🟡 Partial |
| 33 | Can the audit log be altered after the fact? | Shipped. Two mechanisms with different jobs: a trigger refuses `UPDATE` and `DELETE` outright, and every event carries a SHA-256 chained to the previous one, so an operator privileged enough to drop the trigger still cannot make an edit look untouched. `mix ash_enterprise.audit.verify` walks the chains; the suite proves it by tampering. | ✅ Shipped |
| 34 | Can a customer see their own audit trail, and only theirs? | Shipped. The log is attribute-multitenant on an `organization_id` the chain trigger derives from stamped metadata, so a tenant-scoped read is filtered by the data layer rather than by a policy written specially for the audit log. Depth answers how much of a tenant you see; tenancy answers which tenant. | ✅ Shipped |
| 35 | Can an auditor be handed a window of evidence without engineering help? | Shipped. `mix ash_enterprise.audit.export --from --to [--tenant]` writes CSV in chain order, including `sequence`, `previous_hash` and `hash` so the recipient can re-verify it rather than take it on trust. It reads through the ordinary action layer, so an export is exactly as wide as its requester's authorization. | ✅ Shipped |
| 36 | How long is evidence kept, and where does it live after ninety days? | Open. Nothing expires from `audit_events`, nothing is partitioned and nothing moves to cold storage: no migration creates a partition, and the one retention job in the codebase (`AshEnterprise.Lineage.Retention`, 14 days) prunes lineage rows, which are not the evidence. ADR 0024 accepts the design, monthly partitions with ninety days hot and detached partitions that still verify, and its erasure half is built; the partitioning half is not. A twelve-month SOC 2 window is retained because nothing deletes it, not because anything promises to keep it, and the immutability trigger now refuses the `DELETE` that a retention job would need. | ⚪ Open |
| 37 | Are role and permission changes attributable to a person? | Shipped. Role assignments are ordinary audited resources, so granting one produces an event naming the grantor, the grantee and the correlation id of the request — and the record itself now carries `created_by_id`, which nothing populated before. | ✅ Shipped |
| 38 | Where do logs go to be reviewed, and what raises an alarm? | Open. Everything is queryable in Postgres and nothing streams anywhere. Traces can leave through the OTLP exporter when an endpoint is set; the audit log cannot, and there is no collector, alert rule or anomaly rule. ADRs 0018 and 0025 are both still proposed. An auditor asks for evidence that logs are reviewed, not merely kept, and there is none: no review schedule, no rota, no ticket, no record of a human having looked. `ash_compliance` can raise a finding when a control's evidence goes stale, but this host does not schedule that sweep. | ⚪ Open |
| 7 | Is every change recorded, including who and from where? | `AshEvents` writes a central append-only log on every create, update and destroy — inherited from the base resource, not wired per resource, so a new table cannot quietly have no history. Who is recorded: the event names the acting user, and its metadata names a system actor, an automation principal and the person it acted for, or an impersonator, under a correlation id shared by every write of one request. Not recorded: where the change came from. No network address, user agent or client is captured, so a change can be tied to the request that made it but not to the place it was made from. | 🟡 Partial |
| 8 | Can you follow one request across the whole system at 3am? | One correlation id per request, stamped into audit metadata and OTel spans, and carried across process boundaries explicitly. | ✅ Shipped |
| 9 | Are illegal state transitions impossible, or merely discouraged? | `ash_state_machine` generates one named action per legal transition from the canonical Dataverse lifecycle. There is no generic `:update` that can set a state. | ✅ Shipped |
| 12 | How are tenants separated? | Attribute multitenancy on `organization_id`, inherited by every resource — never schema-per-tenant, and never per-department. | ✅ Shipped |
| 13 | Does tenant isolation hold even when authorization is wrong? | Yes, and it is asserted as a separate property: the conformance suite checks isolation independently of every grant path. | ✅ Shipped |
| 14 | Can you erase a person on request? | Partly, by crypto-shredding (ADR 0024's erasure half). Content that arrives through an external connection -- raw landings, canonical messages, conversations and calendar events, and the copies of that content in the audit log -- is sealed under that connection's erasure-scope key, and `shred_scope` destroys the key: rows, structural columns and the audit hash chain survive, the content reads as an explicit `shredded` marker. What is missing for a *person*: nothing yet lands under a `data_subject` scope, `Canonical.Person` names and emails are not sealed, core platform resources (users, organizations) are not covered, and soft delete is still the only delete. Backups and WAL keep the wrapped key until they age out. | 🟡 Partial |
| 15 | Where does the data physically live? | Partly. ADR 0042 declares zones: a jurisdiction, a classification ceiling and the residency restrictions a zone cannot satisfy. Data is admitted into a store only if its own tags are admissible there, and every unknown case (no zone, an untagged row, a malformed tag, a zone past its review date) is refused. The admission rule is built and used on the Gmail and Slack projection path. Nothing is declared by default, so a deployment that declares no zone fails closed; the rule is added per ingest action rather than inherited by every resource; and tenancy is still attribute-based in one database, so physical placement of the database itself is the deployment's. | 🟡 Partial |
| 39 | What crosses the tenant boundary, and to whom? | Open. There is no data inventory, no classification, and no published sub-processor list — which is the first artefact a security questionnaire asks for and the one that has to be current rather than merely written once. | ⚪ Open |
| 40 | What does an AI model see, and can a customer opt out? | Partial. Thesis 5 settles the authorization half: an agent is an actor with an actor's permissions, so a model reaches nothing its user could not. ADR 0042 settles disclosure for inference: an instrument inside the data's own zone is not a disclosure and is recorded in the judgment ledger, and a sub-processor is refused unless the tenant has recorded an opt-in on its organization, which is data and is audited like any update. Every unknown case is a refusal, and `REQUIRE_IN_ZONE_MODELS` refuses sub-processors for everyone. The residency policy test asserts these. Model calls are traced with their provider and model, and by design the spans carry no content; ADR 0026's logging of prompts and responses is still proposed, and there is no tenant-facing report of what a vendor saw. | 🟡 Partial |
| 16 | How does data get in from systems you do not own? | An Oban job runs a Meltano/Singer tap and lands raw rows in an operator-only landing resource sealed for erasure; host-declared projections promote them into ordinary platform resources, so ingested data acquires ownership, tenancy and audit at promotion. Provider APIs (Gmail, Calendar, Slack) land into the same resource through Nango. The schema-to-resource generator is not built. | 🟡 Partial |
| 17 | How do you integrate N SaaS systems without writing N×M integrations? | One contract per category rather than one per (your app × their API). Nango holds the provider edge — OAuth, token refresh, the proxy — and the sync logic stays here as Ash actions over Oban, so a policy gates which actor may trigger a sync and the ordinary audit log records it. Nango's free self-hosted edition gates syncs and webhooks, which is why the design is split that way rather than generated wholesale. Built for Google Calendar, Gmail and Slack (2026-10-12); webhooks are not. | 🟡 Partial |
| 18 | Can you trace a value back to the system it came from? | At the job and dataset level, yes. `ash_open_lineage` emits OpenLineage events from every platform write and every sync, and `AshEnterprise.Lineage` stores them as jobs, runs and job runs, drawn as a graph at `/app/lineage`. A run's id is the correlation id the audit log already carries, so the audit entries of a run and the run of an audit entry are each a lookup. Events carry names only, never an actor, a tenant or a value. Not built: tracing one value back to its source system. Neither Meltano nor Airbyte emits OpenLineage, so the graph has a hole exactly where external data enters, and that is stated rather than drawn over. Lineage rows are kept for 14 days. | 🟡 Partial |
| 19 | What data do you have, and who owns it? | A catalogue populated from codegen — every resource already declares its CDM provenance, ownership type and tenancy scope, so it is a read-only projection rather than a second source of truth. It is an internal tool only: its own RBAC resolves deny-wins, which is the inverse of this project's model. | 🔵 Planned |
| 20 | How do people get reports out of it? | Superset over views already filtered by the same actor context, so the BI tool's row-level security is a formality rather than a duplicate authorization model. Metabase loses because its RLS is paywalled. | 🔵 Planned |
| 21 | The same customer arrived from three systems — which one is real? | In-Ash resolution is built. Source records land with temporal history; deterministic and fuzzy matching are banded by a DMN table; a steward queue takes person-gated verdicts; and a merge picks a winner per attribute under the tenant's survivorship policy, which can rank sources (`source_rank`), records the provenance of each choice with the source and statement it came from, repoints the source identities and can be unmerged, all under one correlation id. The golden record is an ordinary platform resource, so it inherits ownership, tenancy, audit and policy. | ✅ Shipped |
| 41 | How do other systems find out that something happened here? | Open. Events land in the audit log and go nowhere else. There is no outbound webhook, no subscription, and no delivery guarantee for anyone who needs to react to a change rather than poll for it. | ⚪ Open |
| 42 | How does a customer get fifty thousand rows in, or out? | Open. JSON:API and GraphQL paginate, and neither is a bulk path. Import exists only as a Meltano-shaped plan; export exists only for the audit log. | ⚪ Open |
| 55 | How does production data reach an environment where the rules that protect it do not run? | A dump pipeline, not the action layer: greenmask transforms a pg_dump in flight, and its config is generated from the resource declarations by a proposed first-party extension — a `sensitive?` attribute with no declared transform fails generation rather than passing through, and referential continuity comes from greenmask's hash engine with an env-injected salt. The extension is built and public (`lukegalea/ash_greenmask`); this app has not adopted it yet. | 🔵 Planned |
| 22 | How do you move onto this platform from a database you cannot stop? | `ash_strangler` maps a well-modelled resource onto the legacy schema through a closed grammar of typed combinators whose reverses are built rather than guessed, and moves it through four cutover phases without hand-written SQL. 341 tests, including round-trip properties over the legacy value space. **Running here**: `legacy.users` is read through a compatibility view as an ordinary platform resource, a Postgres trigger and listener make that surface live, and the same change is *projected* into a table this application owns -- so there are two live surfaces over the same people, one over the view and one over real columns, and the second is audited where the first structurally cannot be. Still partial, and deliberately: this is not a cutover. The legacy database remains the system of record, and the mapping is not invertible in two documented places (`full_name` cannot be split back into first and last; `company_id` is unmapped), which is exactly what a true cutover would have to resolve. | 🟡 Partial |
| 23 | How do the processes people actually follow get modelled? | `ash_bpmn` compiles a BPMN document into an immutable versioned graph and executes it with a token interpreter over Postgres and Oban, with an embedded designer. Gateway conditions are FEEL, the DMN expression language -- the hand-written expression evaluator it replaced is deleted. **Running here**: the six resources sit on the platform base resource, so a process instance is an ordinary owned, tenant-scoped record and the engine's bypass is the first policy in the base's own set. A published baseline, four seeded requests covering every branch of the gateway, and two tenants on different versions of the same key. | ✅ Shipped |
| 24 | How does an action get a second person's approval before it takes effect? | A change dropped on any action: work item, materialized candidate list, maker-checker exclusion applied by subtraction at candidate resolution rather than as a `forbid_if`, delegation, and escalation timers that get cancelled. **A work item is a platform resource here** -- owned, tenant-scoped and audited -- so who may approve is the same union of grants as who may read, and both the manager and executive approval branches are reachable in the demo. Still partial for one reason: nothing asserts that a user *without* the privilege cannot decide a task, and the positive case passing is not the same evidence. | 🟡 Partial |
| 25 | How do API contracts change without breaking the callers you cannot see? | Version deltas declared as data on the resource — one schema, N presentation contracts, no second table or view — with `render`/`parse` invertibility checked at compile time and sunset proposed from real traffic. | 🔵 Planned |
| 26 | How do you ship a change to some users first? | A flag is evaluated in-process against the application's own database, with actor, business unit and tenant supplied from the context already computed once per request. Policies are not a substitute — they answer *may you*, not *is this on*, and conflating them produces a `beta_user` role you then have to revoke from everyone. | 🔵 Planned |
| 27 | How does the schema itself evolve without drifting from the model? | Migrations are derived as a diff against committed resource snapshots, and the diff is a CI gate — so a resource change without a migration fails the build rather than surfacing at deploy time. | ✅ Shipped |
| 28 | Can you tell what is happening in production? | Instrumentation is the `ash_enterprise_telemetry` package (`telemetry/`, on main): `AshEnterprise.Telemetry.setup/1` registers the Ash tracer, so every action, query and calculation becomes a span with no per-resource wiring, plus Phoenix, Ecto, Oban, outbound HTTP and GenAI spans, with correlation ids carried across them. The OTLP exporter is switched on by `OTEL_EXPORTER_OTLP_ENDPOINT` in `config/runtime.exs`; with it unset nothing is exported, and a bounded in-memory trace ring serves the dev loop. ADR 0065 chose the receiving end, SigNoz for traces, logs and metrics and GlitchTip for errors, superseding ADR 0018, and `devenv/observability` runs both beside the application in development. Not here: this host does not enable error reporting to GlitchTip, and no deployment we operate runs the backends, collects the signals or alerts on them. | 🟡 Partial |
| 43 | Can a deploy happen without downtime, and can a migration be reversed? | Partial. Every generated migration has a `down`, and `ash_strangler`'s four-phase cutover is built precisely so a legacy migration can be reversed at any phase. What is untested is the app's own rolling deploy: nothing proves an old and a new node can serve the same schema at once, which is the property zero-downtime actually needs. | 🟡 Partial |
| 44 | Does it still work for a customer with fifty thousand of something? | Open. No load test, no query budget, and no pagination requirement on read actions — the audit export is the only place in the codebase that streams rather than loads. A reference architecture that has never met a large tenant is making an untested claim. | ⚪ Open |
| 45 | Can a customer change how it behaves without a deploy? | Partial, and less partial than it was. A tenant can fork a process or a decision, edit it in the browser and publish it as its own version, with no binding row meaning 'follow the platform baseline' -- so changing behaviour is data, and reverting is deleting a row. Drift from a newer baseline is reported, never merged. What is still a deploy: adding an attribute is a resource change and a migration, and a decision cannot be tried against sample inputs before it is published. | 🟡 Partial |
| 53 | How are business rules expressed, versioned and changed without a deploy? | As DMN, in `ash_decisions`. A decision is a DMN document -- the single artifact, with no second copy of the rules in a table to drift from it -- versioned and immutable on publish, edited in dmn-js, and evaluated either by a business rule task inside a process or by trigger routing deciding which process to start. The engine is adopted rather than written and measured at 97.68% of the official DMN TCK. `OUTPUT ORDER` and `RULE ORDER` are refused at compile time because both make document order semantically significant, which is the same order-dependence the authorization model rejects. Publishing runs a verifier over every decision table: overlapping rules under `UNIQUE` or `ANY`, gaps in the input space and rules that can never fire are proved, an error-severity finding blocks the publish, and whatever the verifier cannot decide is recorded as an open obligation rather than reported clean. Every evaluation records which version decided, what it saw and which rules fired. What is missing is a way to run a decision against sample inputs from the editor, so an author can still publish without having watched the table fire. | 🟡 Partial |
| 54 | Can a UI built on the new model be driven by a database the old application still owns? | Yes, and it is demonstrated rather than asserted: `INSERT INTO legacy.users` in `psql` reaches a surface generated from `AshEnterprise.Accounts.ProjectedUser` -- an Ash-owned table with real columns -- without a reload and without anything in that surface knowing a legacy database exists. The chain is an `AFTER` trigger, `pg_notify` on commit, a listener that re-reads through Ash so the mapped values apply, a notifier that upserts through an ordinary Ash action, and `Ash.Notifier.PubSub`. What it costs: the projection is eventually consistent, and `projected_at` is a column so the lag is on screen rather than hidden. A row that fails to project is silently absent until the backfill is re-run -- there is no retry. `ash_strangler` ships a `Reconciler` (`diff/2`) that detects this drift, but no host code calls it, so the gap is not closed here. | 🟡 Partial |
| 46 | Which named controls does any of this actually satisfy? | Partial. `docs/COMPLIANCE.md` maps 7 SOC 2 criteria, 4 ISO 27001 controls and 4 GDPR articles to the questions above and through them to the proof of each, generated from the same ledger so it cannot drift. `docs/controls.json` also carries an ownership row for each of the 61 SOC 2 criteria: a class, an owner role, and the evidence producer, operating process and test wherever one exists. 15 rows have nothing missing; 46 still lack a process, a test or a producer, and CI lists every missing piece (`mix ash_compliance.controls.check --report`) while a test refuses a reference that does not resolve. A row says who owns a criterion, not that it operates: no evidence is recorded against any row yet, so none can read as evidenced. The map covers technical prerequisites only; certification also needs policy, process and an auditor, and the document says so first rather than last. | 🟡 Partial |
| 47 | What is promised about uptime, and what happens when it is missed? | Open. No SLO, error budget or status page exists in the repository, and no runbook mentions uptime or an incident. Telemetry exists and nothing is expressed as a target, so there is nothing for an incident to be measured against. | ⚪ Open |
| 48 | How quickly can you come back from losing the database? | Open. Nothing in the repository configures a backup, point-in-time recovery or a restore, and no test or CI job restores a dump. Backups are whatever the deployment provides. No RPO or RTO is committed to, and an untested restore is a belief rather than a control. | ⚪ Open |
| 49 | When something breaks at three in the morning, what happens? | Open. `docs/runbooks` holds five runbooks (amber console, audit sensitive values, crypto-shredding, morning brief, provider operations) and none is an incident or on-call runbook. Alerts go nowhere, no rota exists and nothing says who tells the customer. The correlation id makes the investigation possible; nothing makes it start. | ⚪ Open |
| 50 | What is in the build, and can you prove nothing else is? | Partial. CI runs `mix hex.audit` for retired packages and `mix sobelow` for web vulnerabilities on every push, `mix.lock` pins everything transitively, the Dockerfile pins Elixir, OTP and the base image, and a test fails when a git dependency or an override is missing from `docs/BLEEDING-EDGE.md`. CI has no schedule, so a vulnerability published after the last push is not seen, and no dependency update service is configured. There is no SBOM, no signed build and no provenance attestation, so the dependency set is checked but not attested. | 🟡 Partial |
| 51 | Can you show a control operated continuously for twelve months? | Partial. This is the question the rest of the section is really asking. What exists: an unbroken, verifiable hash chain covering every write, exportable per tenant for any window, and an ownership row for each SOC 2 criterion in `docs/controls.json`. `ash_compliance` now ships a freshness sweep that turns a missing or stale artifact into an unknown finding, but this host neither schedules it nor records an artifact for any control, so nothing here can yet show a control ran for twelve months. Also missing: a retention policy that guarantees the window is still there in month twelve (q36), and any evidence that anyone reviewed it (q38). | 🟡 Partial |
<!-- roadmap:questions-summary:end -->

</details>

The long form, with what each answer is proven by, is [`docs/QUESTIONS.md`](docs/QUESTIONS.md). The ⚪
rows are argued at length in [thesis 7](docs/manifesto/07-what-we-do-not-have.md).

## Getting started

```bash
devenv up -d                            # Postgres (with pgvector)
devenv shell -- mix setup               # deps, database, migrations
devenv shell -- mix ash_enterprise.seed # a tenant, a role, a user
devenv shell -- mix ash_enterprise.demo # the demo tenant: a business-unit tree, people, a clinic
devenv shell -- iex-server              # the app
```

**Nothing to configure for dev or test.** Both boot with built-in session and LiveView
signing salts (`config/dev.exs`, `config/test.exs`), so the commands above are the
whole first run. Those values are public. **Every other environment** (a production
release, or anything that runs `config/runtime.exs` in `:prod`) must set its own
`SESSION_SIGNING_SALT` and `LIVE_VIEW_SIGNING_SALT`, at least 32 characters each and
different from each other. The release refuses to boot, with a message naming the
variable, when one is missing, short, repeated or one of the built-in dev/test
values. Generate each with `mix phx.gen.secret 32`. Names only are listed in
[`.env.example`](.env.example).

**Starting a new application from this template?** Read
[`docs/BLEEDING-EDGE.md`](docs/BLEEDING-EDGE.md) first. Two dependencies are forks of
upstream packages, and 13 of our own packages are not on Hex yet. That page
says which, why, and the path back to a Hex release for each.

`seed` provisions the minimum — one organization, one business unit, one
administrator — which is what tests want and what a first run needs. `demo`
creates a tenant of its own (`clinic-demo`, administrator `demo-admin@example.com`) and fills it,
touching no other tenant, so it is safe on a database that holds real ones. Most of what this platform argues for is invisible against
a single row: grant depth needs a subtree to be measured over, and policies that
differ per actor need a second actor. Everything it creates goes through the
application's own actions, so the people it adds can sign in. Their password is the fixed
`password1234`, for local development only. On an instance other people can reach, run
`mix ash_enterprise.demo --password-file PATH` instead: the people get the password in that
file, a random one is written there (mode 0600) when it does not exist, and it is never
printed. A re-run does not reset the password of a person who already exists.

Sign in with the credentials the seeder prints, then visit:

| URL | What |
|---|---|
| `/app` | The launcher — every surface in the registry (`AshEnterprise.Surfaces`), grouped, Today leading; sign-in lands here (`/app/hub` and `/app/demo` redirect here) |
| `/app/mdm/import` | **MDM demo: import a customer CSV** (upload → AI-proposed mapping → activate → run) |
| `/app/mdm` | **MDM demo: steward queue** — side-by-side diffs awaiting confirm / reject / unsure (reject also in bulk) |
| `/app/mdm/golden` | **MDM demo: golden records** after the confirm, with their source identities and merge history |
| `/app/mdm/batches` | **MDM demo: import batches** as a board by status, each with its counts and staged rows |
| `/app/tasks` | Every process task waiting on you, as a board: claim, complete, delegate |
| `/app/processes` | The `mdm.steward_review` BPMN process the review candidates run (banding itself is a DMN table) |
| `/app/flights/stewardship`, `/app/flights/briefs` | Flight views: a process diagram with a marker on the step each run is on, moved live as the engine advances; `/app/flights` shows one run |
| `/agent` | Helper console — proposes changes for your approval, and shows or composes tables on request |
| `/app/users`, `/app/teams`, `/app/roles`, `/app/business-units` | A2UI surfaces derived from resource metadata |
| `/app/legacy-users` | The same, over a 2010-era Rails schema read through a compatibility view — and it updates when the old application writes |
| `/admin` | Zero-config admin over every resource |
| `/canvas` | The domains, resources and relationships as one object graph, with the selected resource's surface beneath it (dev only) |
| `/clarity` | ER, class, policy and state-machine diagrams (dev only) |
| `/api/json/swaggerui` · `/gql/playground` | JSON:API + OpenAPI, GraphQL |

**The MDM demo, end to end** (fresh DB): sign in as `demo-admin@example.com` /
`password1234` (or the password in your `--password-file`) — the demo tenant owns the demo data.

1. `mix ash_enterprise.demo` seeds the machinery and one in-flight import:
   a golden "Ann Existing" with a merged duplicate, and a review-banded
   match waiting at `/app/mdm`.
2. Upload any CSV at `/app/mdm/import`, click **AI proposal**, review the
   column mapping, **Validate & activate**, then **Run import**.
3. Low-confidence matches land at `/app/mdm`: **Confirm match** merges the
   staged record into its golden; **Reject match** keeps it a separate
   person (several at once, from a selection); **Mark unsure** records the
   verdict and leaves it open for a senior steward.
4. `/app/mdm/golden` shows the survivors and `/app/mdm/batches` the import
   itself; the screens link to each other.

The seeded review candidate is consumed once decided — re-run
`mix ash_enterprise.demo` to reseed one (it is idempotent otherwise).

## What it looks like

No markup was written for any of this. Every surface here is derived from the
same resource definitions: the screenshots are what you get for declaring a
resource, before writing any UI.

**The launcher** at `/app` is the shortest path through all of it, and the
place to start after seeding. It, the nav and the ACP command palette are all
derived from one surface registry, `AshEnterprise.Surfaces`.

![The demo hub, linking the strangler demo, the process modeller, the agents, the diagrams and the admin console](docs/screenshots/demo-dashboard.png)

**A2UI surfaces.** One page per resource, rendered from resource metadata. The
grid, the filter and the tasks are all derived; the actor and the tenant are the
only things the LiveView supplies, so each surface is filtered by exactly the
policies that guard the API.

What a surface offers is derived too, from the actions that exist. A resource
with an update action gets `Edit` on the row; one without gets `View` alone —
which is why `/app/legacy-users` below is read-only without anything in this
application saying so, the strangler read model having declared `defaults [:read]`
and nothing else. Pagination appears when there is another page to go to. A form
appears when you start a task, headed with which task it is, and its button says
what it will do.

What *is* declared is a dozen lines of layout intent per surface — which field is
the title, which is the status badge, what belongs in the metadata grid — because
a derived screen still has to be told what matters. Nothing in that declaration
is styling; A2UI's components carry no spacing or colour props at all, in any
version of the spec. Appearance comes from a CSS custom-property contract that
`assets/css/neobrutalism.css` maps onto the app's design tokens, so these pages
follow the same theme and the same dark/light toggle as the rest of the app
([ADR 0050](docs/adr/0050-neobrutalism-design-system.md)).

![The business-unit surface: seven units as a tree, each row showing its ancestry, with View and Edit per row and a Create business unit action](docs/screenshots/a2ui-business-units.png)

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
fail.

Approving executes it *as you*, through the same policies as the admin UI. The
audit row names the human who approved, not the model that suggested.

Interpreting a request needs a provider key. Everything after it — resolution,
authorization, execution, audit — is ordinary Ash code and does not, which is why
the flow is exercised end to end by the test suite without one.

Not every request is a change, and treating one as if it were is how people learn
to click past confirmations. Asked for a table, the console renders one of the
surfaces the application already declares — filtered by your policies before a
single row reaches the page, so there is nothing to confirm:

![The helper console showing the legacy users table, badged live](docs/screenshots/agent-surface-legacy-users.png)

When no declared surface fits, it composes one. What the model returns is a
**spec**, not UI: a resource name, field names, a sort. The server resolves every
name against a host-configured allowlist and runs the same verifiers the
compile-time DSL runs, so a spec naming a field that does not exist is refused
with an error rather than rendered blank:

![The helper console showing a table the agent composed, with only login and email](docs/screenshots/agent-composed-surface.png)

**A legacy write, showing up.** `legacy.users` is a simulated 2010-era Rails
schema this application does not own — `serial` primary key, no tenant column,
`acts_as_paranoid`, SHA1 passwords. One `ash_strangler` mapping turns it into an
ordinary resource here *and* emits an `AFTER` trigger that `pg_notify`s on
commit. A listener re-reads the row through Ash and dispatches a real
notification, so nothing downstream can tell which application wrote it:

![A legacy user row appearing in the browser moments after a plain SQL INSERT, with a banner saying another application changed these rows](docs/screenshots/legacy-live-update.gif)

Nothing there is staged: the row arrives from a plain `INSERT INTO legacy.users`
issued with `psql` — no Ash, no changeset, no HTTP request. See
[`priv/legacy/README.md`](priv/legacy/README.md) for the commands.

**Master data, end to end.** `/app/mdm/import` → `/app/mdm` → `/app/mdm/golden`
is the entity-resolution loop the ADR 0054 plan asked for, driven entirely
through the UI. Upload a CSV, let the AI propose the mapping (activation stays
a person's act), run the batch, and review-banded matches wait in the steward
queue as side-by-side diffs with survivorship winners:

![The import wizard's mapping step: the CSV columns mapped onto the golden Person record by the AI proposal, with the active mappings listed as data](docs/screenshots/mdm-import-mapping.png)

![The steward queue: a side-by-side diff of the staged record against the golden, with the survivorship winner highlighted and three person-gated acts — confirm, reject, and unsure (which keeps the candidate open for a senior steward)](docs/screenshots/mdm-steward-queue.png)

Confirming merges the staged record into its golden; the golden surface lists
the survivors, with the merge lineage itself answerable as data (`merged`,
`master_id`, the `SourceIdentity` XREF) rather than drawn:

![The golden record surface after the import and the steward's confirm: the imported people are goldens of their own, and the confirmed match folded into its survivor](docs/screenshots/mdm-golden-lineage.png)

**The object graph.** `/canvas` is the application's own structure: every domain,
every resource, and the relationships between them, derived from Ash metadata
alone. No record is ever a node — the graph is declared structure, not a query,
so opening it reads nothing.

![The canvas object graph: the application at the top, thirteen domains beneath it, and their resources below, joined by containment and relationship edges](docs/screenshots/canvas-graph.png)

Selecting a node resolves it server-side into a *naked object*: what it is,
where it came from, one `Ash.can?/3` per action with your actor, and the
*projections* it offers — the ways this application can show it. The graph
focuses on the selection and its immediate neighbours, and the object's own
A2UI surface opens underneath, so the thing you just pointed at is also the
thing you can now browse and edit.

Projections are where the object model stops being a diagram of the database.
Most are derived from the actions a resource declares — a read makes it
browsable, an update makes it editable — but some cannot be. A BPMN process
definition and a business unit have indistinguishable actions; what differs is
that this application ships bpmn-js and points it at one of them, which is a
fact about the host rather than the resource. So the host declares those
([ADR 0037](docs/adr/0037-projections-are-host-declared.md)), and every
projection that has somewhere to go renders as a link beside it. A process
definition offers `diagram` and opens in the modeller; approvals open in the
task list. None of those pages is a derived table, and until they were reachable
this way the whole process layer sat in the graph as objects with nowhere to go.

![The User resource selected: its neighbours highlighted and the rest of the graph dimmed, with the Users surface rendered below](docs/screenshots/canvas-selected-surface.png)

It is dev-only, behind the same flag as `/clarity`, and serves the same
audience.

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

## Compliance engine

Compliance is **projected from events under an immutable rule bundle**
([ADR 0035](docs/adr/0035-compliance-is-projected-from-events.md)). Three
first-party packages carry it; this application wires them into one vertical
slice, customer KYC:

* **`ash_rules`** — the rule engine seam: a serializable rule IR, a
  fact-schema DSL, and evaluator behaviour. Rules are data with verifiers at
  admission, never quoted code.
* **`ash_compliance`** — the control plane and the data plane. Catalogs,
  profiles, waivers and rule-set revisions compile — through a fixed,
  non-negotiable layering precedence — into immutable, content-hashed
  `PolicyBundle` snapshots; findings project out of a compliance event log,
  and every evaluation is appended, pinning the bundle hash, the fact
  snapshot and the outcome. Missing evidence is `unknown`, never compliant.
* **`ash_strangler` (ledger)** — the change ledger the legacy trigger writes,
  and the drain that turns a legacy write into a canonical projection plus a
  KYC review in one transaction, attributed to the projection system actor.

The chain, end to end: **legacy write → ledger row → drain → canonical action
→ event → projector → finding.** The subject reads its own state back as
ordinary calculations (`kyc_status`, `compliant?`, `gap_count` on
`ProjectedUser`); auditors read the evaluation log, which no code path rewrites.

Run the demo program for the legacy estate's tenant:

```bash
mix ash_enterprise.compliance.seed   # catalog, layers, profile, one bounded waiver, active bundle
```

The admin surfaces live at `/app/compliance/*` (findings, evaluations,
bundles, rule sets, catalogs, profiles), behind the compliance door — the same
`(role, privilege, depth)` grant the rest of the security model resolves.

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
| 1 | Audit retention, partitioning and erasure | Time-partitioned hot/cold split; erasure by crypto-shredding | 🟡 Partial | [ADR 0024](docs/adr/0024-audit-retention-and-erasure.md) |
| 1 | Business rules and decision tables | ash_decisions — DMN, engine adopted not written | 🟡 Partial | [ADR 0028](docs/adr/0028-decisions-are-dmn.md) |
| 1 | Control mapping and evidence | Generated from the ledger; SOC 2, ISO 27001, GDPR | 🟡 Partial | [ADR 0021](docs/adr/0021-control-mapping-is-generated.md) |
| 1 | Data ingestion | Meltano (MIT); Airbyte as the fallback | 🟡 Partial | [ADR 0010](docs/adr/0010-meltano-for-ingestion.md) |
| 1 | Enterprise identity: SAML, OIDC and SCIM | Federate to the enterprise IdP over OIDC today; SAML and SCIM as planned strategies on the same seam | 🔵 Planned | — |
| 1 | Integration hub — avoiding M×N | Nango for the provider edge only | 🟡 Partial | [ADR 0011](docs/adr/0011-nango-as-integration-hub.md) |
| 1 | Legacy migration, process modelling and decisions as platform extensions | ash_strangler + ash_bpmn + ash_decisions, first-party | ✅ Shipped | [ADR 0009](docs/adr/0009-strangler-and-bpmn-are-first-party.md) |
| 1 | Lineage and provenance | OpenLineage + Marquez | 🟡 Partial | [ADR 0012](docs/adr/0012-openlineage-and-marquez.md) |
| 1 | Rules and compliance as data | ash_rules (rule IR + swappable evaluators) and ash_compliance (governed layering compiled to immutable bundles, findings projected from events) | ✅ Shipped | [ADR 0035](docs/adr/0035-compliance-is-projected-from-events.md) |
| 2 | AI governance: what leaves the tenant boundary | Prompt/response logging as audit events; per-tenant opt-out | 🔵 Planned | [ADR 0026](docs/adr/0026-ai-governance-is-disclosure.md) |
| 2 | API versioning and deprecation | ash_api_versioning | 🔵 Planned | [ADR 0019](docs/adr/0019-api-versioning-as-presentation-contract.md) |
| 2 | Break-glass and impersonation control | In-Ash: a session resource with a stated reason | 🟡 Partial | — |
| 2 | Data catalog and governance | OpenMetadata (DataHub is the closer call it looks) | 🔵 Planned | [ADR 0013](docs/adr/0013-openmetadata-as-catalog.md) |
| 2 | Log shipping, review and alerting | Structured export to the customer's SIEM; Grafana for ours | 🔵 Planned | [ADR 0025](docs/adr/0025-log-shipping-and-review.md) |
| 2 | Pseudoanonymization of production data | ash_greenmask — config generated from the resource declarations (greenmask, Apache-2.0, adopted not written). The package is built and public at lukegalea/ash_greenmask; this app has not adopted it yet | 🔵 Planned | [ADR 0032](docs/adr/0032-anonymization-config-is-generated.md) |
| 2 | Reporting and embedded analytics | Apache Superset over Metabase | 🔵 Planned | [ADR 0014](docs/adr/0014-superset-over-metabase.md) |
| 2 | SLOs, disaster recovery and incident response | Committed RPO/RTO with a tested restore; error budgets | 🔵 Planned | — |
| 3 | Bulk import and export | Ash bulk actions over a staged upload | 🔵 Planned | — |
| 3 | Data inventory, classification and sub-processors | Derived from resource metadata, not maintained by hand | 🔵 Planned | — |
| 3 | Feature flags and progressive delivery | FunWithFlags (Unleash rejected) | 🔵 Planned | [ADR 0016](docs/adr/0016-unleash-for-feature-flags.md) |
| 3 | Observability backend | SigNoz and GlitchTip | 🟡 Partial | [ADR 0065](docs/adr/0065-signoz-and-glitchtip-observability-backends.md) |
| 3 | Outbound events and subscriptions | An Ash notifier over the existing event log | 🔵 Planned | — |
| 4 | Master data and entity resolution | In-Ash resolution over CDM resources | 🟡 Partial | [ADR 0054](docs/adr/0054-mdm-stewardship-is-system-one.md) |
| 4 | Performance at enterprise data volumes | A seeded large tenant and a query budget | 🔵 Planned | — |
| 4 | SBOM and build provenance | CycloneDX SBOM; attested builds | 🔵 Planned | — |
| 4 | Zero-downtime deploys and reversible migrations | Expand/contract, proven by a two-version test | 🔵 Planned | — |
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
| [`docs/COMPLIANCE.md`](docs/COMPLIANCE.md) | **The control map** — SOC 2, ISO 27001 and GDPR controls, and the test that proves each |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | Where the gaps go, in what order, and what each choice beat |
| [`docs/HANDOFF.md`](docs/HANDOFF.md) | **Start here in a new session** — current state, and findings that cost time to discover |
| [`docs/manifesto/`](docs/manifesto/00-index.md) | The eight theses, including [what we do not have](docs/manifesto/07-what-we-do-not-have.md) |
| [`docs/adr/`](docs/adr/README.md) | Decision records, with the reversal path for each |
| [`docs/BLEEDING-EDGE.md`](docs/BLEEDING-EDGE.md) | **Forks and unreleased packages** — what is not a Hex release, and the path back for each |
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

**Thesis 4 currently claims field policies that `lib/` does not
contain.** The claim is being corrected rather than quietly implemented.

## Licence

MIT — see [`LICENSE`](LICENSE). Two vendored corpora are excluded and carry their
own terms (see [`NOTICE.md`](NOTICE.md)): `priv/cdm/schemaDocuments/` is Microsoft's Common Data Model under
CC-BY-4.0, and `priv/cdm/resolved/dataverse_*.json` derives from Microsoft's
Dataverse table reference. Attribution is required for both; see
[`priv/cdm/ATTRIBUTION.md`](priv/cdm/ATTRIBUTION.md).

This is a template, not a product. Clone it, delete what you do not need, and
keep the shape.
