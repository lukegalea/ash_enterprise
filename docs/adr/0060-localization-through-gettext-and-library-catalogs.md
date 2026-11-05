# ADR 0060 — Localization through Gettext and library-shipped catalogs

- **Status:** accepted, in progress (2026-11-05). Phases 1 and 2 are built; phases 3, 3b and 4 are not
- **Date:** 2026-10-29, reworked 2026-11-04
- **Implementation note:** 2026-11-05, at the end of this record

## Context

User-visible text here comes from four places, each with a different owner and release cycle:

1. **Host copy:** HEEx templates, flashes, and host A2UI DSL titles. It is static, lives in source control and ships
   with a deploy.
2. **Library copy:** strings owned by a dependency. Examples are `ash_a2ui`'s encoder chrome ("Save changes",
   "Showing …", "Select page"), its ActionHandler feedback ("Created successfully."), labels it humanizes from field
   names, Atlas element chrome, and Ash's own error messages. The host can't see these with an ordinary
   `mix gettext.extract`, because the strings aren't in the host's source.
3. **Formatting:** dates, numbers and currency. This is a CLDR concern, not message translation.
4. **Tenant-authored content:** for example a requirement catalog entry's title. This is data, with tenant scope,
   residency constraints and possibly review.

The first draft of this record (2026-10-29) proposed a new package, `ash_translations`, covering all four cases.
Before adding a package, we checked what the ecosystem already provides. All observations are from 2026-11-04.

**Ash core already ships the pattern for library copy.** Ash 3.37.2, the version this repository locks, ships it.
- `Ash.Gettext.error_message/1` is a no-op marker macro, so Ash takes no runtime Gettext dependency.
- `mix ash.gettext.extract` scans for the marker and writes `priv/gettext/ash.pot`, which ships inside the Hex
  package.
- In the host, `mix ash.gen.gettext [--domain errors]` copies that template in. It can also merge the template into
  an existing domain between `## -- ash-gettext:start --` markers, and its docs expect several libraries to keep
  their own sections in one domain.
- At runtime the host translates with `Gettext.dgettext(Backend, domain, msg, vars)`.

The runtime hook shape is also settled. `ash_authentication_phoenix` takes `gettext_fn: {module, function}` or
`gettext_backend: {module, domain}`, calls `apply(module, function, [msgid, bindings])`, and substitutes `%{key}`
itself when neither option is given. Splode errors carry `vars`, and AshPhoenix exposes `{message, vars}` so they
can be translated.

**Two existing packages translate records. Neither one fits case 4 as stated, and neither touches cases 1–3.**

- **`ash_translation`** (TimisRobert, 0.2.6, about 200 lines, last commit 2026-04-04).
  - A Spark extension that adds an embedded `translations` attribute, a `%{locale => %{field => text}}` map, to a
    resource.
  - Locales come from a CLDR backend at compile time. `translate/1` overlays the map on read, using the ambient
    CLDR locale.
  - It ships AshPhoenix nested-form helpers.
  - It has no Gettext integration, no review step, no staleness tracking and no tenant awareness. Locale fallback
    is an open issue (#8).
  - It is a reasonable answer for unreviewed per-field record translation, and nothing more.
- **`ash_phoenix_translations`** (raul-gracia, 1.0.1, about 17,000 lines).
  - Per-field JSONB storage, plus a "Gettext backend" keyed on `resource.field.record_id`.
  - It also bundles plugs, a LiveView mixin, GraphQL and JSON:API extensions, and a cache GenServer.
  - Its transformer injects role-based edit policies, which conflicts with
    [authorization as a union of grants](../manifesto/03-authorization-is-data.md).
  - It requires Phoenix, and it resolves the locale ambiently.

**LLM generation of PO files has prior art and isn't Ash-specific.** `gettext_llm` and `gettext_translator` both
translate PO files through LangChain. Neither uses ReqLLM, which this platform standardizes on.

**State when this was written (2026-11-04, before phases 1 and 2 landed; see the implementation note):**
- This repository's main branch has `priv/gettext/errors.po` only. The French credentialing showcase
  (`?locale=fr`, a `showcase` domain with `fr` plurals) is on `dogfood`.
- Keystone already calls `gettext/1` about 170 times, but has no default-domain catalog, no `fr`, no
  `put_locale`, and a hard-coded `<html lang="en">`.
- `ash_a2ui` has no locale hook. Its `humanize/1` is copied into ten modules, and many ActionHandler messages
  interpolate `inspect/1` output.

So a new package would mostly re-create Ash's own catalog pattern under a name one letter away from
`ash_translation`. It would also put a speculative content-review engine (case 4) into a library before any consumer
exists.

## Decision

**No new package.** Each kind of text is localized by whoever owns it, through Gettext, using the conventions Ash
already ships. Each phase below names the repository it changes.

### 1. Host copy is plain Gettext

Host templates and LiveViews use `gettext`/`dgettext`/`ngettext`. Host DSL titles are wrapped in `dgettext_noop` so
`mix gettext.extract --merge` sees them. No custom extractor is built for anything that is a literal in host source.
Count-bearing strings are resolved on the server with `ngettext`, because client-side templating can't pluralize.

Authentication screens get the `gettext_backend:` option that `ash_authentication_phoenix` already accepts.

**Who approves the words.** Merging a catalog PR is the approval for platform copy, and code owners approve code,
not French. A change to a French catalog therefore also needs the approval of a named French language reviewer,
enforced by a `CODEOWNERS` entry on the French `.po` files. Machine-drafted text is a proposal until that reviewer
approves it. The reviewer and the generation task (section 3) work from the same checked-in glossary.

### 2. Library copy follows Ash's catalog pattern, inside each library

A library that renders user-facing text owns its catalog. **`ash_a2ui`** adopts the pattern; its contract is
specified in ash_a2ui issues (lukegalea/ash_a2ui#65) rather than here:

- A no-op marker around every encoder-owned and ActionHandler string.
- `mix ash_a2ui.gettext.extract`, which writes a shipped `priv/gettext/ash_a2ui.pot`.
- `mix ash_a2ui.gen.gettext [--domain]`, which reuses Ash's marker-section merge.
- An optional `gettext_fn:`/`gettext_backend:` option, in the same shape as `ash_authentication_phoenix`.
- An explicit `locale:` on build, refresh and dispatch, for both v0.9.1 and v1.0.
- When the option is omitted, output is unchanged byte for byte, and protocol goldens prove it.
- Two prerequisites:
  - Collapse the ten `humanize/1` copies into one label resolver; that resolver is the single place a label is
    translated.
  - Turn ActionHandler messages into templates with `vars`, and drop `inspect/1` from user-facing feedback.

Boundary rules carried over from the first draft:
- Translate only resolved display metadata, the encoder chrome whitelist and ActionHandler templates.
- Never recursively translate payloads.
- Never translate identifiers, paths, enum values, action or field names, option values, or record data.
- Each displayed string is translated exactly once.
- A missing translation resolves to the `msgid`.

**Host display metadata.** A field label generated from `:due_date` isn't in anyone's source. Host display metadata
(labels, help, descriptions, enum labels) is translated through a second Gettext domain, `metadata_domain:`
(default `"a2ui_metadata"`).
- `mix ash_a2ui.gettext.extract_metadata` writes that domain's `.pot` by encoding every surface with a recording
  translator, so the msgids are exactly the labels shown. `--check-up-to-date` gates CI.
- Enum values use `msgctxt "enum:<Module>"`.

**Atlas chrome (Keystone).** Atlas elements contain no English.
- Per-instance text arrives as slots or attributes from HEEx.
- A2UI payloads carry resolved strings, never keys.
- Element-internal chrome, such as "Close", "Previous page", "Loading" and the upload hints, comes from one
  Gettext-resolved strings map. The root layout renders that map per request and the base element reads it.
- There is no JavaScript-owned catalog.
- The only locale logic in the browser is `Intl` formatting keyed off `<html lang>`.
- The A2UI catalog swaps stop adding their own words.

### 3. PO generation is a design-time host task

Machine translation of platform catalogs is a mix task in the host that a person runs: Expo for PO I/O, plus ReqLLM
structured output.

- It runs in deterministic, ordered, bounded batches with source context and a glossary.
- It rejects missing, invented or duplicate msgids, empty strings, placeholder or plural mismatches, and invalid PO.
- A fake adapter tests malformed model output.
- Its output is idempotent.
- CI checks catalog freshness and never calls a model.
- No model is called at compile time or on read.

Try `gettext_translator` before writing the task. (It was tried and not adopted; the implementation note says why.)
The task becomes a standalone package, named without an `ash_`
prefix since nothing in it is Ash-specific, only when a second repository wants it.

### 4. Tenant-authored content is deferred, with a decision rule

There is no consumer today with a known recipient locale. When one arrives:

- **Per-field translation without review:** use `ash_translation`, and contribute an explicit-locale
  `translate/2` and fallback upstream (its issue #8) rather than fork it.
- **Content that needs review or carries legal meaning:** a host resource on the platform base. Translations are
  keyed by source key and source hash, a revision becomes immutable on submission, and approval is bound to the
  exact revision and hash. Ordinary reads never return draft, pending or rejected revisions. A changed source falls
  back to the source text until a matching revision is approved. Resolution is set-oriented, by tenant and locale,
  and never one query per label. Review, if needed, is a host BPMN process under ordinary policies.
- In both cases tenant content never overrides platform copy, and model-generated text is only ever a proposal. The
  one sanctioned override is an organization's wording overlay (section 5).

The first candidate stays `Clm.RequirementCatalog.title`, and only once its report projection carries
`catalog_entry_id`. `EmailTemplate` and `ComposeLive` are not pilots.

### 5. Locale selection and propagation

- Precedence: user preference → organization (`Organization.languagelocale_id` → `Reference.LanguageLocale.code`)
  → `Accept-Language` → `en`. `Accept-Language` is the last fallback, because it is the only signal a JSON:API call
  has before a preference is stored.
- **The user preference is the one the legacy web app already stores.** Its language switcher writes `users.locale`
  (`en` or `fr`), and the users twin already carries that column. Keystone reads it there rather than adding a
  second preference, so a person sees the same language in both apps. ActorContext loads it with the actor, so
  resolution adds no query. Keystone does not write it while the web app owns the users table.
- Validate codes as BCP 47 without creating atoms. Map them to Gettext locales only at the adapter boundary. A
  language-only code maps to the regional catalog the host ships: `fr-CA` and the stored `fr` both become `fr_CA`
  in Keystone, and `fr` in ash_enterprise.
- Resolve the locale after actor and tenant resolution, and after the `LiveUserAuth` mirror. Pass it explicitly to
  A2UI and ACP; don't rely on the ambient process locale.
- **Work with no request** (renewal and expiry notices, digests, other Oban jobs) resolves a locale per recipient
  when it builds each message: the recipient's preference → the recipient's organization → the sending
  organization → `en`. A job carries recipient ids, never a locale captured at enqueue, and sets the locale for
  each message explicitly (`Gettext.with_locale/3` around that message only).
- **Organization wording overrides.** The legacy web app lets an administrator override platform copy for one
  organization, in English and French, keyed by its own translation keys. Keystone must not contradict that wording.
  Overrides apply as an overlay translator: the organization's overrides are loaded once per request into
  ActorContext, keyed by domain, msgid and locale, and consulted before the Gettext backend. Host copy reaches it
  through one host translation helper, and A2UI through `gettext_fn`. Only display strings are overridable, never
  identifiers or values. The open question is the mapping from the web app's keys to msgids: only keys that name the
  same string in both apps carry over. Until the overlay is built this is a known gap: an organization with
  customized wording sees the default wording in Keystone.
- Render `<html lang>` dynamically. A mid-session preference change triggers a remount, so the root layout re-renders.
- URL locale selection is not supported. The credentialing showcase's `?locale=` is a documented demo exception.
- CLDR formatting (`ex_cldr`) is a separate, later concern. It takes an explicit locale and preserves timezone,
  currency and date-only semantics.

### Rollout

| Phase | Repo | Work | State (2026-11-05) |
|---|---|---|---|
| 1 | ash_a2ui | Single label resolver, templated ActionHandler messages, marker, `extract`/`gen` tasks, `gettext_fn`/`locale:` option, goldens for both protocols | built |
| 2 | ash_enterprise | Locale resolution and `<html lang>`, `gettext_backend` on auth routes, generation task, `fr` catalogs, run `extract_metadata`, dogfood the ash_a2ui option | built (#66, #67) |
| 3 | Keystone | The same locale plumbing; `fr_CA` catalogs for existing `gettext` calls; run `extract_metadata`; Atlas strings map; `ProcessLive` plurals; `ContractsHubUI` pilot; user preference from the users twin; per-recipient locale in notification jobs | not built |
| 3b | Keystone | Organization wording overlay, once the web app's keys are mapped to msgids | not built |
| 4 | Both hosts | CLDR formatting | not built |
| — | Host | Tenant content, only under the rule in section 4 | not built |

### Release gates

- A2UI goldens for initial build, refresh, options and action feedback on v0.9.1 and v1.0. These prove output is
  unchanged without the option, and that with it only whitelisted display strings change, each exactly once.
- Catalog freshness in CI (`mix gettext.extract --check-up-to-date`), PO validity, and placeholder and plural
  validation. The generation task's fake adapter rejects malformed output.
- Host metadata catalog current (`extract_metadata --check-up-to-date`).
- Every change to a French catalog approved by the French language reviewer.
- A real root `lang` attribute. `ProcessLive` counts of 1 and 2 with interpolation. `ContractsHubUI` labels
  translated while record values are unchanged. Locale parity between ACP and A2UI.
- French and pseudo-locale checks on post-render dialogs and toasts.

## Does it consume ActorContext?

Static catalog lookup is pure and reads no actor or tenant data. Locale resolution reads the actor's preference and
organization, which ActorContext has already loaded, so it adds no query. The organization's wording overrides, once
built, are loaded into ActorContext once per request in the same way. Design-time extraction and generation never
read tenant records. Tenant content, if it is ever built, is an ordinary platform resource under ordinary policies,
with no translation-specific ACL.

## Consequences

**Made easy.** Localization uses tools every Elixir developer knows. Library strings are translated the same way
Ash's own errors already are, so a host learns one workflow. Nothing new needs to be published, named or maintained.
Static copy has no runtime dependency on a model, a database or an actor.

**Made hard.** Each library that renders text has to adopt the marker-and-catalog convention itself; `ash_a2ui`
first, then Atlas through the host strings map. Host metadata catalogs must be regenerated whenever a surface changes. Tenant
content stays unsolved until a consumer forces the decision. Every French catalog change waits for a French
reviewer.

**Foreclosed for now.** A new package for translation. A database-backed static catalog, or a read per label.
Generic attribute translation. Tenant text replacing platform copy outside the organization wording overlay. Compile-time or on-read model calls. Recursive
payload rewriting. A JavaScript-owned catalog. Ambient locale at the A2UI and ACP boundaries. URL locale selection
outside the showcase.

## Reversal

The static phases are Gettext calls and PO files. Removing them means restoring literal strings at the call sites;
there is no data migration. Reverting the `ash_a2ui` option means removing an optional argument whose default is the
current behavior. If a package turns out to be warranted later, for example because several libraries need a
label-walking extractor, these catalogs become its input unchanged. If tenant content was built on `ash_translation`,
reversing it means dropping one embedded attribute per resource, after exporting any approved text the customer's
contract requires us to keep.

## Implementation note — phases 1 and 2 (2026-11-05)

Phases 1 and 2 landed in ash_enterprise as #66 (locale resolution, `fr` catalogs, the generation task) and #67
(ash_a2ui catalogs and an explicit locale at every A2UI boundary), against the ash_a2ui release this repository locks.
Where the code differs from, or settles, the text above:

- **Locale resolution** is `AshEnterpriseWeb.Locale`, gathered per request by `AshEnterpriseWeb.Plugs.PutLocale` and
  carried into LiveViews by `AshEnterpriseWeb.LiveLocale`. The root layout renders `<html lang>` from it. A2UI, ACP,
  GraphQL and MCP receive the locale explicitly, through `Locale.a2ui_opts/1` for A2UI.
- **The user preference is a seam.** This repository has no legacy users table, so `Locale.user_preference/1` answers
  `nil` until a user field is added. Reading the legacy `users.locale` (section 5) is Keystone's phase 3.
- **The organization's locale is one read in the plug**, made once per request after `LoadActorContext`, rather than
  a field ActorContext loads. It still never runs inside a policy check.
- **Authentication screens** use `gettext_backend: {AshEnterpriseWeb.Gettext, "auth"}`.
- **The generation task** is `mix l10n.generate` (`AshEnterprise.L10n.Generator`, Expo and ReqLLM, a fake translator
  in tests) with a glossary at `priv/l10n/glossary.fr.json`. `gettext_translator` 0.9.3 was evaluated first and not
  adopted: it depends on LangChain, translates one message per call without a glossary or context, writes unvalidated
  output, and is not idempotent. The task's moduledoc has the full reasoning.
- **CI gates** run `mix gettext.extract --check-up-to-date` and `mix ash_a2ui.gettext.extract_metadata
  --check-up-to-date`. Neither calls a model.
- **Not yet in place:** the `CODEOWNERS` entry naming a French language reviewer (section 1). The `fr` catalogs that
  landed are machine-drafted and still need that review.
