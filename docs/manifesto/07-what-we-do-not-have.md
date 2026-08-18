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

**What is missing is adopting it here.** ADR 0009 named three gaps in the package — an authorizer on every generated
resource with no `policies` block behind it while the engine passed `authorize?: false` at roughly ninety internal call
sites; a `:tenant` option that `AshBpmn.start_instance/2` accepted and discarded; resource macros emitting
`use Ash.Resource` themselves, so a human task could not sit on the platform base resource. All three were closed
upstream on 2026-08-18, and the package's suite grew from 176 tests to 202 proving it.

What is left is the composition, plus one decision that came out of the fix and belongs here rather than there. Ash
folds policies into a single expression in which a bypass short-circuits only the policies declared *after* it, and a
base resource emits its policy set from `use` — ahead of anything `ash_bpmn` adds. So a work item on
`AshEnterprise.Platform.Resource` reaches the engine's bypass second, and the engine is forbidden, unless
`AshBpmn.Checks.AshBpmnInteraction` goes at the top of `AshEnterprise.Security.Policies` or the engine is configured to
act as a `SystemActor` that set already admits. Until one of those is done and an approval actually runs here, "an
approval is an ordinary owned, audited, tenant-scoped record" remains a design intent rather than a fact about *this*
codebase — the obstacles are gone, the demonstration is not there yet.

**→ Roadmap:** [ADR 0015 — approvals and process modelling stay inside Ash](../adr/0015-approvals-stay-in-ash.md)
and [ADR 0009 — `ash_strangler` and `ash_bpmn` are first-party](../adr/0009-strangler-and-bpmn-are-first-party.md).

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

**→ Still open.** No decision taken. This is the hardest of the open entries, because it needs a design rather than a
tool.

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
