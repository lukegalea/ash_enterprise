# Thesis 7 — What we do not have

> The honest list. A reference architecture that hides its gaps is marketing, not engineering.

Read this one before committing to the stack. Everything below was verified in August 2026; each entry says what is
missing, how much it costs, and what to do about it.

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

## 2. SAML 2.0

No SAML support anywhere in the ecosystem. OIDC covers most modern identity providers, and `ash_scim` covers user
*provisioning* from Okta / Entra ID / OneLogin — but a customer who requires SAML SSO specifically cannot be served
without building it.

For many enterprise sales cycles this is a blocking requirement. Know it before the RFP.

## 3. Approval workflows / maker-checker

There is no Ash extension for the single most requested enterprise workflow pattern: an action that requires a second
person's approval before it takes effect, with delegation, escalation, and an audit trail of who approved what.

**What we do about it:** compose it. `ash_state_machine` for the approval lifecycle, policies for who may approve,
`AshEvents` for the trail, and `Reactor` where an approval fans out into multiple downstream effects. This works, and it
is genuinely more code than the rest of the security model combined.

## 4. Dialyzer certainty

There is **no official guidance anywhere** on running Dialyzer against Ash or Spark. No canonical ignore file, no PLT
recommendations, no troubleshooting page. Spark builds resources through heavy macro expansion, and Dialyzer is well
known to produce spurious warnings on generated code.

**What we do:** `dialyxir` is included with PLT caching and runs in CI **non-blocking**, with `.dialyzer_ignore.exs`
seeded empirically rather than aspirationally. The real gates are `mix compile --warnings-as-errors`, Credo with
`ash_credo`, and Elixir 1.18's built-in type checker.

This is the weakest-documented area of the entire ecosystem, and we would rather say so than ship a config that implies
a rigour we have not verified.

## 5. Data retention, purge, and right-to-erasure

`ash_archival` is **soft delete only**. There is no extension for hard purge on a retention schedule, no anonymization
or pseudonymization pipeline, and no tooling for a GDPR Article 17 erasure request that has to reach the audit log and
the event store as well as the row.

This is a real gap for anything holding EU personal data, and it interacts awkwardly with [thesis 4](04-batteries-are-inherited.md):
an immutable central audit log is exactly what a right-to-erasure request runs into. Design the retention story
deliberately; do not assume soft delete is compliance.

## 6. Analytics and warehouse data layers

No Trino, Presto, Snowflake, or BigQuery data layer exists. (`ash_trino` does not exist, despite appearing in various
summaries.) Ash reaches operational stores well and analytical stores not at all — plan on CDC or ETL out to the
warehouse rather than expecting Ash to query it.

## 7. Internationalization

Three competing packages — `ash_translation`, `ash_trans`, `ash_phoenix_translations` — none with meaningful adoption
and no clear winner. Phoenix's Gettext covers UI strings; **translated *content*** (a product name in six languages,
stored per-tenant) has no settled answer.

Ironically the CDM models this well: `is.localized.displayedAs` carries a `[languageTag, displayText]` table on every
entity and attribute. We currently read only the `"en"` row, which is also all the upstream corpus populates.

## 8. Reporting and document generation

`ash_typst` and `ash_reports` are both early and lightly adopted. Enterprise buyers expect pixel-controlled PDF
invoices, statements, and regulatory filings. Budget for this as bespoke work.

## 9. OpenTelemetry depth

`opentelemetry_ash` is at 0.1.3 and is thin relative to what enterprise APM expects — expect to extend it. Ash's own
`:telemetry` events and `Ash.Tracer` are rich; the *bridge* to OTel is what is immature. `ash_appsignal` is more
polished, and is the integration the Ash docs actually endorse, at the cost of vendor lock-in.

## 10. No canonical deployment guide

There is no Ash-specific deployment documentation. Releases, migrations-as-release-commands, tenant migrations at
deploy time, `config :ash, :disable_async?`, and AshOban plugin configuration in `runtime.exs` are all things you must
assemble yourself from Phoenix guides plus reading. We do that assembly here — but we invented it rather than following
a blessed path.

## 11. Feature flags

No `ash_feature_flags`. Use `FunWithFlags` or build it; there is no Ash-native answer, and policies are not a
substitute (they answer *may you*, not *is this on*).

---

## What this list is not

It is not an argument against the stack. Every one of these gaps exists in most frameworks; the difference is that they
are usually discovered in month nine rather than stated on page one.

It is also a snapshot. `ash_authentication` 5.0 landed TOTP; `reactor` reached 1.0; `ash_scim` appeared and made
enterprise provisioning tractable. Several entries here will be obsolete within a year — **re-verify before making a
decision on the strength of this page**, and update it when you do.

The commitment this repository makes is not that there are no gaps. It is that we will name them.
