# ADR 0060 — First-party localization with `ash_translations`

- **Status:** proposed
- **Date:** 2026-10-29

## Context

The platform has several different kinds of user-visible text, different owners, and different release lifecycles. Framework and platform chrome is static product copy and belongs in source control. Tenant-authored content is data, may have residency constraints, and needs tenant-scoped authorization and review. A single translation mechanism would either put tenant content in deploy artifacts or turn static UI labels into database lookups.

A2UI produces text from resource/DSL declarations, generated labels, protocol encoders, and action feedback. Ordinary Gettext extraction cannot see every label: some are resolved dynamically from Ash metadata and some are literals owned by the A2UI encoder. A2UI currently has v0.9.1 and v1.0 protocol paths; localization must not fork their existing signatures or alter payload data. Phoenix-host concerns must remain at the host boundary rather than making localization reusable code inside one Phoenix application.

The `ash_translation` Hex package exists (0.2.6 observed 2026-10-29) and describes a different scope. At decision time, `https://hex.pm/packages/ash_translations` returned 404 and GitHub repository checks for `lukegalea/ash_translations` and `ash-project/ash_translations` returned 404. These checks do not prove that every owner/namespace is available; validate the intended Hex owner and GitHub namespace immediately before package creation. The provisional plural name is intentionally distinct from the existing singular package.

## Decision

Build a standalone, first-party package provisionally named **`ash_translations`**. It is reusable library code, not code embedded in this Phoenix host. Dogfood it in `ash_enterprise`. Confirm Hex and GitHub ownership before publishing or reserving the package; if unavailable, stop and obtain an explicitly approved distinct name rather than silently colliding with `ash_translation`.

Use a hybrid architecture:

1. **Platform/framework static copy:** checked-in Gettext PO catalogs. Translation is resolved from compiled catalogs; there is no database storage, per-label query, or model invocation during compile/runtime/read. Platform catalog changes are reviewed and approved by merging a PR.
2. **Opt-in tenant copy:** tenant-scoped Ash-managed source entries and immutable locale revisions. This path is for explicitly enabled tenant-owned display content only; it does not override platform chrome in v1.

No compile-time or runtime-on-read LLM is permitted. Static-catalog generation is an explicit design-time bulk operation, with deterministic ordered bounded batches, source context and glossary. The intended tasks are `mix ash_translations.extract`, `mix ash_translations.generate --locale fr-CA`, and `mix ash_translations.check`. Generation MAY use an optional AshAi/ReqLLM structured-output adapter, but the core must work without a model. CI never invokes a model. Generation/checking rejects missing, invented or duplicate message IDs, empty translations, placeholder/plural mismatches, and invalid PO; generated output must be deterministic/idempotent. Platform translations enter through a verified PR and merge, not direct runtime writes.

### Message identity and extraction

A static message is identified by its source `msgid` plus stable semantic `msgctxt`, not by source line number. Include generated Ash labels. Implement extraction using Ash/A2UI-aware introspection that resolves declarations, defaults, and encoder-owned literals; ordinary gettext extraction alone is insufficient. `mix ash_translations.check` must detect both missing catalog entries and obsolete/stale source entries and provide actionable diagnostics.

### Runtime lookup and A2UI boundary

Every A2UI boundary receives locale explicitly; do not depend on ambient process locale. Add an optional locale/localizer contract additively and coordinate it with `ash_a2ui`, preserving all current behavior and existing call signatures for callers that do not opt in. The integration localizes exactly:

1. resolved DSL/resource display metadata, including generated labels;
2. a closed whitelist of encoder-owned chrome in both v0.9.1 and v1.0;
3. known `ActionHandler` feedback/error templates across build, refresh, and dispatch.

Do not recursively translate arbitrary payloads. Never translate identifiers, paths, enum values, action names, field names, relationship option labels, or arbitrary record data. No generic translate-all-attributes API and no parallel JavaScript translation catalog. Define ownership so each displayed string is translated exactly once; localization must not double-translate.

Missing, stale, or unapproved translations resolve to the source text. A failed or absent translation never hides the source value.

### Tenant-managed source and immutable revisions

Model a stable source key, source locale, source text, source hash, and context. Each locale revision has locale, translated text, status (`draft`, `pending`, `approved`, or `rejected`), and the source hash it translates. Revision content becomes immutable on submission. Ash actions and lifecycle state are authoritative. Approval applies only to the exact revision and exact source hash; stale approval fails. Draft, pending, and rejected revisions are never returned by ordinary resolution. Rejection leaves a prior approved revision usable only when it is for the same current source hash. A source-text/hash change invalidates prior approval and resolution falls back to source until a matching revision is approved.

Expose a bulk authorized resolve operation for all requested source keys for one tenant and locale. It returns source fallback for absent/stale/unapproved entries and performs bounded set-oriented resolution, never one query per label. A review preview may display an explicitly selected draft by revision ID under review authorization, without exposing drafts through normal read/resolution paths.

Tenant generation is permitted only through a host-configured, residency-compliant/in-zone generator or a human path, and always creates proposals only. `ash_translations` MUST NOT depend on `ash_bpmn`. A host-owned `translation.review` BPMN process MAY orchestrate a HumanTask. Any process `ActionInvoker` integration requires reviewed allowlist entries, a subject summary/reference, reviewer candidates, maker-checker exclusions, and tenant policies. ADR 0015 remains proposed pending its negative authorization test; mandatory translation gates include negative authorization, tenant isolation, and maker-checker tests regardless of that ADR's status.

### Keystone locale and host integration

In Keystone, reuse `Organization.languagelocale_id` and `Reference.LanguageLocale.code`. Add `User.preferred_language_locale_id` only after an explicit host schema decision during implementation; do not presume it exists. Locale precedence is user preference, then organization locale, then `en`. Validate locale codes without atom creation: accept/validate BCP 47 externally and normalize to Gettext conventions only at the adapter boundary.

Load locale after actor/tenant resolution and the `LiveUserAuth` mirror so the chosen locale uses the same identity and tenant context as the request. Render the root `<html lang>` dynamically. Propagate locale explicitly to A2UI and ACP and assert parity. Initially, do not select locale from URL or `Accept-Language`.

### Rollout and explicit boundaries

1. Deliver core package, A2UI integration, and `ash_enterprise` dogfood.
2. Add Keystone locale propagation and `ProcessLive` interpolation/plural support; pilot A2UI in `ContractsHubUI`.
3. Complete static catalogs for registry, shell, ACP, Atlas, flashes, authentication, and errors.
4. Add explicit-locale CLDR formatting while preserving timezone, currency, and date-only semantics.
5. Add tenant-managed revisions and the host-owned BPMN review process.

A first managed-content consumer MAY be exactly `Clm.RequirementCatalog.title`, only when its report projection carries `catalog_entry_id` and bulk-resolves display text. Legally meaningful tenant text must be explicitly enabled and reviewed. If there is no real consumer with a display/recipient locale, defer host managed-content adoption; do not invent a consumer. Package lifecycle remains deliverable and testable independently. Do not use `ComposeLive` as a pilot (it is operator-only and nonpersistent). Do not start with `EmailTemplate`: it has no reliable recipient locale.

Atlas labels are server-owned only. Inventory `dialog.js` `closeLabel="Close"` and `toast.js` fallback `"Close"`; preferably require caller-provided localized labels and remove English fallbacks. If defaults remain, include them in the extraction inventory. Gate with pseudo-locale and French checks that cover post-render dialogs and toasts.

### Does it consume ActorContext?

At runtime, static PO lookup is pure and has no actor or tenant data. The opt-in managed path does consume the host's ActorContext: all managed source/revision reads and lifecycle actions run through Ash authorization and tenant scope, and no translation package bypass or parallel ACL is allowed. Bulk resolve is an authorized host-facing operation, not an unfiltered cross-tenant catalog read. Design-time extraction and PO generation do not consume ActorContext and must never read tenant records. A host BPMN process consumes the host ActorContext through its ordinary policies and candidate resolution; `ash_translations` itself does not import the process engine.

## Consequences

**Made easy.** Platform copy is reviewable, reproducible, and shipped with the application; tenant copy can be localized without deploying each approved change. Static and tenant lifecycles have distinct storage, review, and fallback rules. A2UI display text can be localized without corrupting protocol identity or user data. The package remains usable outside Phoenix.

**Made hard.** Extraction needs Ash/A2UI introspection in addition to Gettext's ordinary source scan. Two catalogs/authoring paths require clear ownership and documentation. Any model use requires an explicit human-run design-time command, context/glossary discipline, and output validation; model output is untrusted. Tenant-managed localization adds authorization, revision immutability, source-hash currency, review UI/process integration, and bulk-query obligations. Locale propagation must be explicit at each boundary, including LiveView and ACP.

**Foreclosed in v1.** Database-backed static PO, per-label reads, generic attribute translation, tenant overrides of platform chrome, automatic compile/runtime LLM calls, recursive payload rewriting, arbitrary data translation, a JS-side catalog, ambient locale, URL/Accept-Language selection, and a `ash_bpmn` dependency from the package.

## Implementation-ready plan

Execute as a dependency-aware sequence; keep the package core independent of the Phoenix host and of `ash_bpmn`.

### Phase 0 — package and contract checks

- Verify intended Hex owner and GitHub namespace availability and secure ownership before creating/publishing. Inspect the existing `ash_translation` package's declared scope only to document the namespace distinction; do not depend on it or claim equivalence.
- Inspect current `ash_a2ui` protocol and ActionHandler contracts for v0.9.1/v1.0. Agree the optional locale/localizer API with maintainers before implementation. Specify default behavior, lookup ownership, and call-site boundaries in tests first.
- Inventory dependencies, supported Elixir/Ash versions, licensing, and package release conventions. Define a core with Gettext/PO and Ash lifecycle responsibilities; put Phoenix/LiveView, ACP, ReqLLM, and BPMN integration behind host/optional adapters.

### Phase 1 — static package lifecycle

- Create standalone package, formatter/docs/usage rules, CI, and test fixtures; add `ash_enterprise` as the first consumer using the repository's dependency convention.
- Implement semantic stable message IDs, Ash/A2UI-aware extraction of declaration metadata, defaults, generated labels and protocol-owned literals, plus catalog completeness/staleness checks.
- Implement deterministic extraction and ordered bounded generation with glossary/context, structured-output validation, PO syntax and placeholder/plural validation, and idempotence. Keep model adapter optional; add a fake adapter for malformed responses. Never make CI call a model.
- Add initial platform catalogs and PR review workflow. Document that merging the verified catalog PR is approval.

### Phase 2 — A2UI additive locale support

- Coordinate changes in `ash_a2ui` and `ash_translations` as an additive optional locale/localizer contract; preserve existing signatures and output when omitted.
- Localize only resolved display metadata, explicit encoder-owned chrome allowlists for both protocols, and known ActionHandler feedback/error templates on build/refresh/dispatch. Keep option values and arbitrary payloads untouched.
- Add protocol goldens for initial build, refresh, options, and action feedback for both protocols; assert only whitelisted display strings differ and prove there is no double translation.
- Inventory Atlas close/toast labels, remove English defaults in favor of caller-provided labels where feasible, otherwise extract retained defaults. Test French and pseudo-locale after render.

### Phase 3 — host locale propagation and static coverage

- Reuse Keystone `Organization.languagelocale_id` / `Reference.LanguageLocale.code`; decide explicitly whether to add the user preference field before schema changes. Implement precedence user → organization → `en`, BCP47 validation without atom creation, adapter normalization, and locale loading only after actor/tenant and LiveUserAuth mirror.
- Render `<html lang>` and propagate explicit locale to A2UI and ACP. Add ACP/A2UI parity tests. Do not add URL or `Accept-Language` selection.
- Add `ProcessLive` interpolation and plural support, and `ContractsHubUI` A2UI pilot. Complete extraction coverage for registry, shell, ACP, Atlas, flashes, authentication, and errors. CI checks extraction and catalog freshness only; no generation/model call.

### Phase 4 — formatting

- Add explicit-locale CLDR formatting as a separate concern from message translation. Preserve timezone selection, currency semantics, and date-only values; prove these are not silently converted by locale formatting. Do not localize enum/option values or arbitrary record data.

### Phase 5 — managed tenant revisions and optional review

- Add tenant-scoped Ash source/revision resources, stable keys and source hashes, immutable-on-submit transitions, exact revision/hash approval, stale-approval failure, and source fallback rules.
- Implement bulk authorized resolution by tenant+locale with bounded query count and per-key fallback. Keep drafts invisible except explicit authorized preview by ID.
- Add tenant proposal generation only through a configured in-zone/residency-compliant host adapter or human entry; ensure generation never approves.
- Add cross-tenant, unauthorized, requester-self-approval, ineligible-reviewer, immutable-submission, stale-source, previous-approved-on-rejection, and changed-source fallback tests. Treat negative authorization and tenant/maker-checker isolation as release gates.
- Only after a real consumer is ready, optionally enable `Clm.RequirementCatalog.title` under the exact report-projection `catalog_entry_id` + bulk-resolution condition. Otherwise leave host managed-content consumer deferred while shipping/test-driving package lifecycle. If BPMN is enabled, keep `translation.review` host-owned, `ash_bpmn` optional and separate, and review each invoker allowlist/policy/candidate configuration.

### Required verification and release gates

- A2UI golden coverage: initial render, refresh, options and action feedback on v0.9.1 and v1.0; prove only display text changes.
- Extraction completeness and staleness, stable IDs independent of line moves, PO validity, placeholder/plural validation, malformed fake ReqLLM output rejection, and deterministic idempotence.
- Managed fallback, exact source-hash approval, stale-approval refusal, old-approved behavior after rejection for unchanged source, invalidation after source change, preview isolation, and bounded query counts.
- Cross-tenant resolution/read denial, requester self-approval denial, and ineligible reviewer denial; all must be negative tests, not positive-path inference.
- Real UI root `lang`; `ProcessLive` counts 1/2 plus interpolation; `ContractsHubUI` labels translated while record values remain unchanged; ACP/A2UI locale parity; French and pseudo-locale screenshots/behavior for post-render dialogs and toasts.
- Run the repository's documented precommit and platform-battery gates after implementation lands. Update `docs/BLEEDING-EDGE.md` when the new package becomes an unreleased dependency and keep package/repo `usage_rules` synchronized. This ADR-only change itself does not claim those implementation checks have run.

## Kickoff prompt

Copy and paste the following when starting implementation:

> Implement ADR 0060 (`docs/adr/0060-first-party-localization-with-ash-translations.md`) in dependency order. This is an implementation task, not an ADR rewrite: first revalidate Hex/GitHub ownership for `ash_translations` and inspect the live `ash_a2ui` v0.9.1/v1.0 and ActionHandler contracts. Coordinate an additive optional locale/localizer API without breaking current signatures or default output. Build the standalone first-party package and dogfood it in `ash_enterprise`; keep Phoenix, ACP, ReqLLM and BPMN adapters at optional host boundaries, and never make `ash_translations` depend on `ash_bpmn`. Implement checked-in Gettext PO static copy with Ash/A2UI-aware extraction and `extract`, `generate --locale`, `check` tasks; deterministic bounded generation, strict structured-output/PO/placeholder/plural checks, a malformed fake-model test, and no model call in CI. Keep tenant-owned copy in a separate opt-in Ash source + immutable locale-revision lifecycle with source-hash-bound approval, source fallback, authorized bulk resolution, draft isolation, and proposal-only in-zone generation. Localize only the declared A2UI display metadata, whitelisted encoder chrome in both protocols, and known ActionHandler feedback/errors; never rewrite IDs, paths, enum values, action/field names, relationship option labels, or arbitrary record values, and prevent double translation. In Keystone use existing Organization/LanguageLocale references, make any User preference field an explicit schema decision, load locale after actor/tenant plus LiveUserAuth mirror, render dynamic root `lang`, propagate explicit locale to A2UI/ACP, and do not add URL or Accept-Language selection. Follow rollout and all negative-security, fallback/hash, bounded-query, golden, extraction, fake-generation, interpolation/plural, locale-parity and French/pseudo-locale gates in the ADR. Do not invent a managed-content pilot: enable only the specified RequirementCatalog projection case when its catalog_entry_id and bulk display resolution are actually available; otherwise defer host adoption while completing package lifecycle. Update BLEEDING-EDGE and usage_rules when dependencies/docs require it, and run documented precommit/platform-battery checks only after all implementation edits are complete.

## Reversal

Remove the `ash_translations` dependency and its host adapters, revert the coordinated optional A2UI locale contract, and restore source strings at explicit display boundaries. Static PO files and generated catalog tasks can be removed without data migration. For managed copy, first export/retain approved tenant content in a host-owned archival format if it is contractually needed, then remove the opt-in resources, actions, and review process; no static catalog or arbitrary record is rewritten by the package. Reverting only the managed phase leaves static Gettext localization intact. Reverting the package entirely costs the extraction/generation tooling and localized catalogs, but existing product strings remain source-resolvable; it does not require data schema changes from the static phases.
