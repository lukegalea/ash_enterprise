# Thesis 7 — What we do not have

> The honest list. A reference architecture that hides its gaps is marketing, not engineering.

Read this one before committing to the stack. Everything below was verified in August 2026 and re-verified on
2026-08-18; each entry says what is missing, how much it costs, and what to do about it. Five of the twelve entries now
have a decision recorded in [`docs/adr/`](../adr/README.md) and say so at the end; the rest are still open, and say that
too.

---

## 1. Passkeys / WebAuthn / FIDO2

**The largest gap.** `ash_authentication` has no WebAuthn strategy — not in stable 4.x, and not in the 5.0 release
candidates. There is no community package on hex either.

This matters because passkeys are increasingly a procurement checkbox rather than a nice-to-have, and because the
alternative we ship (password + TOTP) is the thing security teams are trying to move away from.

**What exists instead:** password, magic link, OAuth2, OIDC, API keys, and — in the 5.0 RC line — TOTP with recovery
codes.

**Work-around:** implement a custom strategy through `ash_authentication`'s `providers` extension point, over `wax` or
`webauthn_components`. This is real work, not a weekend.

> ⚠️ If you adopt the 5.0 RC for TOTP, **pin ≥ `5.0.0-rc.10`**. Releases rc.0 through rc.9 are flagged on hex.pm as
> carrying security advisories.

**→ Still open.** No decision taken.

## 2. SAML 2.0

No SAML support anywhere in the ecosystem. OIDC covers most modern identity providers, and `ash_scim` covers user
*provisioning* from Okta / Entra ID / OneLogin — but a customer who requires SAML SSO specifically cannot be served
without building it.

For many enterprise sales cycles this is a blocking requirement. Know it before the RFP.

**→ Still open.** No decision taken.

## 3. Approval workflows / maker-checker

An extension for the single most requested enterprise workflow pattern now exists, and it is first-party.
`ash_bpmn` supplies an action that requires a second person's approval before it takes effect, with delegation,
escalation, and an audit trail of who approved what: an `Ash.Resource.Change` dropped on any action, a materialized
candidate list, maker-checker exclusion applied by subtraction at candidate resolution rather than as a `forbid_if`,
and remind/escalate/expire timers that are Oban jobs whose ids are stored on the task so they actually get cancelled.

**It is adopted here now** — this entry was rewritten on 2026-08-20, later than the rest of the page. Twelve resources
sit on `AshEnterprise.Platform.Resource`: six from `ash_bpmn`, two from a second first-party package `ash_decisions`,
and four written here for triggers and bindings. An `AccessRequest` submission is one audited write; a trigger matches
it, a FEEL guard filters it, a versioned DMN decision routes it, and a process with a business rule task, an exclusive
gateway and human tasks runs to a granted role or a parked approval. The engine's authority is a policy bypass rather
than an `authorize?: false` at a call site, so it keeps the human actor and the audit entry still names the person who
approved. `AshBpmn.Expr` — 571 hand-written lines of tokenizer, parser and evaluator, with a `String.to_atom/1` on
tenant-authored XML and a bare `rescue _ -> {:ok, false}` in it — was deleted, and FEEL replaced it, so the platform has
one expression language rather than two. Both authoring surfaces are wired: bpmn-js for processes and dmn-js for
decisions, each opening a tenant's own draft, with forking an explicit act on a button rather than a side effect of
opening an editor. The design is in [`docs/plans/ash-bpmn-in-reference-app.md`](../plans/ash-bpmn-in-reference-app.md)
and [`docs/plans/decisions-and-feel.md`](../plans/decisions-and-feel.md); every collision it caused is in §4 of the
first.

**So this entry is no longer about approvals. It is about business rules, and seven things are missing.** In descending
order of how much they cost:

1. **An author cannot try a decision before publishing it.** The DMN editor landed: `/app/decisions` has a
   "Customize" button that forks a baseline, `/app/decisions/:key/editor` opens dmn-js on the resulting draft, and the
   save/publish lifecycle is covered by tests. What it has no way to do is **evaluate** — there is no panel for feeding
   the table sample inputs and seeing which row fires, so a rule author publishes a decision having never once watched
   it answer. `Evaluation` rows exist and are only written by a business rule task at runtime, which means the first
   real evaluation of a newly published rule happens in a live process. For a layer whose entire premise is that
   non-developers change business logic, "you may edit it but not test it" is the gap that matters most, and it is
   ours to close rather than the engine's.

   The narrower editing gap alongside it: **there is still no FEEL editor.** `@bpmn-io/feel-editor` is MIT and would
   give literal expressions and input entries syntax highlighting and autocompletion, and it is present only as an
   unused transitive dependency of dmn-js. So the most error-prone text in a decision table is typed into a plain box.

2. **Publish-time overlap and completeness analysis does not exist.** This was meant to be the thing `ash_decisions`
   offers over a hosted DMN engine, and it is designed and unbuilt: no overlap check, no completeness check, no
   decidable/undecidable distinction, and no obligations mechanism. The design is sound and the technique is already
   proven next door — `ash_strangler`'s proof-obligation engine ([ADR 0008](../adr/0008-typed-invertible-legacy-mappings.md))
   does exactly this shape of work, decidable by finite-domain enumeration and interval algebra for cells that are
   S-FEEL unary tests over enumerable domains or numeric intervals, with the undecidable remainder carried as unproven
   obligations re-checked at runtime. **None of it is code.** The consequence is concrete: a `UNIQUE` table with two
   overlapping rules publishes without complaint, and the conflict surfaces as a runtime error on the first case that
   matches both rows. An error rather than a silent wrong answer, and much later than it needed to be found.

3. **The audit trail can say a decision was evaluated and what it returned, but not why.** This is the real hole in
   the evidence story and it is worth stating in its own right rather than as a caveat. `Evaluation.matched_rule_ids`
   is always `[]` and `TriggerDispatch.fired_rule` is always `nil`, because `Boxic.DMN.evaluate/3` returns the
   decision's value and nothing about how it reached it. So an auditor asking *"which rule denied this request?"* can
   be shown the inputs, the outputs, the definition version and the timestamp, and cannot be shown the row. Computing
   a second opinion is refused on purpose: one that disagreed with the engine that actually decided would be worse
   than no answer. It is an upstream limitation, the columns are already there, and until it is closed the decision
   trail is one question short of the one people ask.

   Alongside it, a smaller compile-time gap: decision table **input entries are not parsed at publish time**. They are
   unary tests, a grammar the engine parses inside its evaluator rather than exposing, so they are size-bounded at
   compile time and validated when they first run. A table can publish with a malformed cell and fail on the first
   case that reaches that column.

4. **FEEL's three-valued logic is not uniform, and the asymmetry is a diagnostic hole.**
   `subject.missing > 100` is `null` and the interpreter records a `:condition_null` event. `subject.missing = true` is
   plain `false` and records nothing, because equality against `null` is defined. So an ordering comparison on an absent
   field leaves evidence and an equality comparison on the same absent field takes the default branch silently. That is
   FEEL to specification rather than a defect, which is exactly why it belongs on this page: it is a permanent property
   of the language we chose, it will surprise whoever hits it, and the only mitigation is that it is written down.

5. **A tenant can sit indefinitely behind a baseline.** Drift is *reported* — "customized · forked from platform v3 ·
   platform is now v5" — and never merged. That is the right refusal: the two XML documents have diverged and
   reconciling them is the round-tripping problem in another costume. But refusing to merge is not the same as having an
   answer, and the honest description of the current state is that a customized tenant accumulates distance from the
   platform with a badge, a side-by-side viewer, and no path back.

6. **There is no export, for anything in flight.** [ADR 0009](../adr/0009-strangler-and-bpmn-are-first-party.md)'s
   reversal section says *"In-flight process instances are lost; there is no export"*, and the plan for this work named
   `mix ash_decisions.export` as a day-one requirement specifically so that admission would not be knowingly repeated.
   It was not built; `ash_decisions` ships two mix tasks and both are conformance tasks. Two facts soften it and neither
   closes it: the authored XML is a column, so every definition survives a `COPY`, and all instance state is ordinary
   rows in this application's own tables rather than in an engine's private schema. The data is not lost. There is no
   migration path to another engine, and that is what an export would be.

7. **The engine underneath is tier 3, and the reasons it is defensible are the reasons to keep watching it.**
   `boxic_dmn` 0.3.0 and `boxic_feel` 0.2.0 are Apache-2.0 packages by a single author with negligible adoption.
   Adopting them was a measured decision — an independent run of the official DMN TCK, written here against the
   published packages, put them at **97.68%** of 3,495 asserted result nodes, which is the alternative to a 60–90
   person-day FEEL implementation. Four things bound what that number certifies, and each is a real cost:
   - **It is a statement about DMN 1.5 documents.** `dmn-js` emits DMN **1.3**, and the engine refuses anything but
     1.5. `AshDecisions.Dmn.Profile` rewrites the namespace URIs on the way into the engine and never on the way to
     storage, and `mix ash_decisions.tck --downgrade` re-runs the whole corpus rewritten to 1.3 to prove the rewrite
     changes no answers. That is a well-tested mitigation for an integration that does not work out of the box.
   - **It is gated by CI, not by `mix test`.** The suite is a mix task. Someone running the tests locally will not
     notice a conformance regression, and 81 result nodes remain outstanding.
   - **`libxml2` is now a runtime dependency of loading any DMN document.** The engine validates against the normative
     XSD by shelling out to `xmllint`, because the packaged OTP `xmerl_xsd` cannot compile that schema's derivation
     graph. It is in `devenv.nix`, in CI, and in the `Dockerfile`'s runtime stage, and `AshEnterprise.Application`
     warns at boot when it is absent — but **without the binary every model fails to load**, and a rules engine that
     silently has no rules is a bad failure mode to have acquired from a dependency.
   - **We depend on a package whose stated Elixir constraint we violate.** Both boxic packages declare
     `elixir: "~> 1.20.0"`. This repository pins Elixir 1.18.4 on OTP 27, to match what the Ash ecosystem is tested
     against. They compile and pass here — the conformance run is the evidence — but *compiles and passes* is not
     *supported*. Either upstream relaxes it, or we pin `boxic_* 0.1.x`, or the toolchain moves.

   What makes the dependency defensible rather than reckless is narrow and should be stated as narrowly as it is true:
   the engine is called from **one module per package**, and **the conformance suite is ours**. A replacement is
   therefore one module to write and a number to compare against, rather than a search. Remove either of those
   properties and this would not be a dependency to take.

**→ Decided.** Six records: [ADR 0009 — `ash_strangler` and `ash_bpmn` are
first-party](../adr/0009-strangler-and-bpmn-are-first-party.md),
[ADR 0015 — approvals and process modelling stay inside Ash](../adr/0015-approvals-stay-in-ash.md),
[ADR 0027 — FEEL is the one expression language](../adr/0027-feel-is-the-expression-language.md),
[ADR 0028 — decisions are DMN, measured against the TCK](../adr/0028-decisions-are-dmn.md),
[ADR 0029 — process configuration is tenant data](../adr/0029-process-configuration-is-tenant-data.md) and
[ADR 0030 — events trigger processes through a dispatched cursor](../adr/0030-events-trigger-processes.md). The seven
items above are what those records do not close.

## 4. Dialyzer certainty

There is **no official guidance anywhere** on running Dialyzer against Ash or Spark. No canonical ignore file, no PLT
recommendations, no troubleshooting page. Spark builds resources through heavy macro expansion, and Dialyzer is well
known to produce spurious warnings on generated code.

**What we do:** `dialyxir` is included with PLT caching and runs in CI **non-blocking**, with `.dialyzer_ignore.exs`
seeded empirically rather than aspirationally. The real gates are `mix compile --warnings-as-errors`, Credo with
`ash_credo`, and Elixir 1.18's built-in type checker.

This is the weakest-documented area of the entire ecosystem, and we would rather say so than ship a config that implies
a rigour we have not verified.

**→ Still open.** No decision taken.

## 5. Data retention, purge, and right-to-erasure

`ash_archival` is **soft delete only**. There is no extension for hard purge on a retention schedule, no anonymization
or pseudonymization pipeline, and no tooling for a GDPR Article 17 erasure request that has to reach the audit log and
the event store as well as the row.

This is a real gap for anything holding EU personal data, and it interacts awkwardly with [thesis 4](04-batteries-are-inherited.md):
an immutable central audit log is exactly what a right-to-erasure request runs into. Design the retention story
deliberately; do not assume soft delete is compliance.

**It got harder on purpose in August 2026.** The audit log is now hash-chained and carries a trigger that refuses
`UPDATE` and `DELETE`, so the collision is no longer theoretical: the log actively rejects the deletion an erasure
request implies, and removing a row would break the chain even if the trigger allowed it. That is the integrity
guarantee working, and it means the retention design can no longer be postponed by pretending the two requirements
might not meet.

**→ Roadmap:** [ADR 0024 — retention: partition for age, crypto-shred for erasure](../adr/0024-audit-retention-and-erasure.md).
Proposed, not built. It is the hardest decision in the set and the least reversible — encryption is one-way for anyone
whose key has already been destroyed — which is the argument for designing it before it is urgent rather than during an
incident.

## 6. Analytics and warehouse data layers

No Trino, Presto, Snowflake, or BigQuery data layer exists. (`ash_trino` does not exist, despite appearing in various
summaries.) Ash reaches operational stores well and analytical stores not at all — plan on CDC or ETL out to the
warehouse rather than expecting Ash to query it.

**→ Still open.** No data layer is proposed and nothing on the roadmap changes that. Two records address the adjacent
need from either side — [ADR 0010](../adr/0010-meltano-for-ingestion.md) for getting external data *in* through an
ordinary platform resource, and [ADR 0014](../adr/0014-superset-over-metabase.md) for querying it *out* over generated
views — but both keep the analytical store outside Ash rather than behind a resource.

## 7. Internationalization

Three competing packages — `ash_translation`, `ash_trans`, `ash_phoenix_translations` — none with meaningful adoption
and no clear winner. Phoenix's Gettext covers UI strings; **translated *content*** (a product name in six languages,
stored per-tenant) has no settled answer.

Ironically the CDM models this well: `is.localized.displayedAs` carries a `[languageTag, displayText]` table on every
entity and attribute. We currently read only the `"en"` row, which is also all the upstream corpus populates.

**→ Still open.** No decision taken.

## 8. Reporting and document generation

`ash_typst` and `ash_reports` are both early and lightly adopted. Enterprise buyers expect pixel-controlled PDF
invoices, statements, and regulatory filings. Budget for this as bespoke work.

**→ Partly decided.** [ADR 0014 — Superset over Metabase](../adr/0014-superset-over-metabase.md) covers the reporting
half: ad-hoc analysis, dashboards and scheduled exports over views already filtered by the same actor context. It does
nothing for the document half. **Pixel-controlled PDF generation is untouched and stays open.**

## 9. OpenTelemetry depth

`opentelemetry_ash` is at 0.1.3 and is thin relative to what enterprise APM expects — expect to extend it. Ash's own
`:telemetry` events and `Ash.Tracer` are rich; the *bridge* to OTel is what is immature. `ash_appsignal` is more
polished, and is the integration the Ash docs actually endorse, at the cost of vendor lock-in.

That version has not moved: **0.1.3, published 2025-07-11**, thirteen months stale as of 2026-08-18. The repository is
not dead — the last several commits are dependency bumps, with no feature work since.

Two things are true of *this repository* specifically, verified 2026-08-18. `OpentelemetryPhoenix.setup/1` and
`OpentelemetryEcto.setup/1` are **never called** anywhere in `lib/` or `config/`, so those two declared dependencies
emit nothing and the only spans produced are Ash's. And `config/config.exs` says the OTLP endpoint is set in
`config/runtime.exs`, which contains **no OpenTelemetry configuration at all**. Instrumentation here is declared, not
wired.

**→ Named, not closed.** [ADR 0018 — Grafana LGTM as the observability backend](../adr/0018-grafana-lgtm-observability-backend.md)
picks a destination. This entry is about the bridge, and a destination does not thicken a bridge — the record says so
itself.

## 10. No canonical deployment guide

There is no Ash-specific deployment documentation. Releases, migrations-as-release-commands, tenant migrations at
deploy time, `config :ash, :disable_async?`, and AshOban plugin configuration in `runtime.exs` are all things you must
assemble yourself from Phoenix guides plus reading. We do that assembly here — but we invented it rather than following
a blessed path.

**→ Still open.** No decision taken.

## 11. Feature flags

No `ash_feature_flags`. Use `FunWithFlags` or build it; there is no Ash-native answer, and policies are not a
substitute (they answer *may you*, not *is this on*).

**→ Roadmap:** [ADR 0016 — feature flags: FunWithFlags, not Unleash](../adr/0016-unleash-for-feature-flags.md).
Unleash was expected to win the comparison and did not, for two reasons worth carrying forward. It **relicensed
Apache-2.0 → AGPL-3.0 at v8.0.0** (released 2026-06-09), and the OSS edition is capped at **one project and two
environments**. And its Elixir SDK is community-maintained and **silently ignores segments and flag dependencies** —
the strategy evaluator reads only `strategy["constraints"]` — so a flag the Unleash UI says excludes a user evaluates
`true` for them, with no error anywhere.

## 12. Column-level security

[Question 6 on the checklist](../QUESTIONS.md) — "are some columns more sensitive than the rows that contain them?" —
is answered "not yet", and this is the entry behind it. `grep -rn "field_polic" lib/` returns nothing: there is not one
field policy declared anywhere in this repository. [Thesis 4](04-batteries-are-inherited.md) listed field policies among
what the base resource supplies until 2026-08-18, which made it the one place where a claim ran ahead of the code; that
line has been corrected rather than implemented.

This is a gap of omission rather than difficulty, which is what makes it worth naming separately from the rest of this
page. Ash field policies gate columns on the same additive model thesis 3 uses for rows, so nothing has to bend to
accommodate them. The nouns exist too: `FieldPermission` and `FieldSecurityProfile` are already resolved in the corpus
(`priv/cdm/resolved/dataverse_field_permission.json` and `dataverse_field_security_profile.json`) and nothing reads
them.

**What it costs:** any column a role should not see — a salary, a national id, a negotiated rate — is readable today by
anyone the row policies admit, through every derived surface at once: JSON:API, GraphQL, `ash_admin`, A2UI and the MCP
tools all read the same fields. And unlike the other cross-cutting concerns, this one is not finished by declaring it
once. The base resource can supply the mechanism; naming which fields are sensitive stays a per-resource judgement, so
the inheritance argument of thesis 4 only gets you half way.

**What to do about it:** declare a `field_policies` block on `AshEnterprise.Platform.Resource` with a catch-all
`field_policy :*` that authorizes, so no existing surface changes, then attach field grants to the same
`(role, privilege)` rows `AshEnterprise.Security.ActorContext` already resolves once per request — the same rule about
checks never querying applies, and the precomputed privilege map is already the right shape to carry them.

**→ Still open.** No decision taken. [The roadmap](../ROADMAP.md) lists it under what stays open rather than sequencing
it.

---

## What this list is not

It is not an argument against the stack. Every one of these gaps exists in most frameworks; the difference is that they
are usually discovered in month nine rather than stated on page one.

It is also a snapshot. `ash_authentication` 5.0 landed TOTP; `reactor` reached 1.0; `ash_scim` appeared and made
enterprise provisioning tractable. Several entries here will be obsolete within a year — **re-verify before making a
decision on the strength of this page**, and update it when you do.

The commitment this repository makes is not that there are no gaps. It is that we will name them.
