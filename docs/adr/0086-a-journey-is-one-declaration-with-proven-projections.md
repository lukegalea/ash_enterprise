# ADR 0086 — A journey is one declaration, and every projection shows only what a passing run of it recorded

- **Status:** accepted (2026-11-26; proposed 2026-11-21), built in part: the declaration, the runner, lock and
  approve, the docs pages and the in-app guide exist; the evidence sinks, the agent tools and the Cucumber Messages
  export do not
- **Date:** 2026-11-21
- **Related:** [ADR 0020](0020-tamper-evident-audit-log.md) (the tamper-evident audit log),
  [ADR 0021](0021-control-mapping-is-generated.md) (a control may claim only what the ledger proves),
  [ADR 0024](0024-audit-retention-and-erasure.md) (erasure),
  [ADR 0033](0033-experience-layer-adoption.md) (the A2UI experience layer),
  [ADR 0038](0038-models-observe-declarations-decide.md) (models observe; declarations decide),
  [ADR 0039](0039-judgments-are-declared-questions.md) and [ADR 0068](0068-paper-separates-schema-layout-theme-and-wording.md)
  (declarations locked by hash), [ADR 0060](0060-localization-through-gettext-and-library-catalogs.md) (Gettext),
  [ADR 0065](0065-signoz-and-glitchtip-observability-backends.md) (browser spans are untrusted; amended with this
  record), [ADR 0067](0067-a-document-is-a-pure-function-of-recorded-inputs.md) (stored bytes are the record),
  [ADR 0070](0070-upstream-first-placement.md) (upstream-first placement)

## Context

The same user paths were walked several times, by different means, and nothing checked that the walks agreed.
Verified at `origin/main` on 2026-11-21:

- `ash_browser_tests` generates a real-browser test for each declared surface and each A2UI row action, asserts the
  OpenTelemetry chain each test produced, and fails the suite when a declared surface is neither exercised nor
  waived with a written reason (`AshBrowserTests.Ledger`). No ADR named the package; the decision to adopt it lived
  only in its README.
- Screenshots for the docs and the site are taken by a separate script (`scripts/screenshots/capture.mjs` over
  `priv/scripts/screenshot_data.exs`), run by hand against a hand-started server. Walkthrough prose lives in
  `docs/showcase/`, and `assets/e2e/*.spec.ts` drives some of the same paths again.
- The application had no end-user help.
- `docs/COMPLIANCE.md` says of the control map: "no evidence is recorded against any row yet". A row with a test
  says that a test file exists, not that the control operates.

Each walk can go stale on its own. A screenshot can show a button that was renamed, a walkthrough can describe a
step the code no longer has, and a passing test can prove a path nobody documented. ADR 0021 solved the same problem
for the control map with one rule: a control may claim only what the ledger proves. This record applies that rule to
how-to documentation, in-app help and the evidence a browser run can produce.

The design follows long-standing prior art. Specification by Example (Adzic, 2011) and Living Documentation
(Martraire, 2019) keep an executable specification as the documentation. The Screenplay pattern (Serenity BDD) models
actors, the tasks they perform and the questions they ask. Concordion and Doc Detective treat documentation as test
input. Storybook makes one declaration serve as documentation, catalogue and test at component scope. Diátaxis
separates tutorials and how-to guides from reference and explanation.

## Decision

**A journey is one typed, versioned declaration of how one persona reaches one goal. Tests, figures, docs pages,
in-app help, evidence and agent answers are projections of it, and a projection may show only what a passing run of
the same journey version recorded.**

### 1. The journey

A journey is written in a Spark DSL (`ash_journeys`). It names its personas, the seeded world it starts from, a goal
and an outcome, and an ordered list of steps. Each step has a persona, one act, its expectations, its narration and,
optionally, figures and notes. The first, `AshEnterprise.Journeys.Offboarding` (`:revoke_a_leavers_access`), is in
English and French.

- **Step targets are references, not prose or selectors.** An act names a surface registry id
  (`AshEnterprise.Surfaces`) or an A2UI manifest row action. Spark verifiers check at compile time that each
  reference exists. A start-of-run check (`AshJourneys.Preflight`) covers what only the surfaces as a run renders
  them can confirm, such as whether a row action asks for confirmation as the journey declares. A renamed surface or
  action fails the build or the run, never the reader. Not built yet: Ash actions, state-machine transitions and BPMN
  user tasks as act targets, and a start-of-run check of each persona's door and `Ash.can?` against the seeded
  world.
- **Expectations are observable facts:** the page a step lands on, a record's state after it, and the trace and audit
  facts of the [ADR 0065 amendment](0065-signoz-and-glitchtip-observability-backends.md).
- **Narration is authored, never generated.** Each string is a Gettext msgid in a `journeys` domain, translated by
  the existing loop (ADR 0060). `ui/1` interpolates the label the manifest resolves for the locale being rendered.
  A run records every text it resolved (`texts` in the run manifest), and a projection shows text only while it
  still resolves the same, so a renamed button or a changed translation reaches a page only with a new approved run
  whose figures show it; an unknown reference fails verification. A model
  may draft narration for a person to accept, as ADR 0038 allows; a model's critique of a figure or a sentence is
  advisory and never gates.
- **Kinds are `:tutorial` and `:how_to` only.** Reference pages come from the resource and action declarations, and
  explanation stays hand-written, as Diátaxis separates them.

The declaration compiles to an intermediate representation (`AshJourneys.Info.ir/2`) whose content hash is the
SHA-256 of its RFC 8785 canonical JSON, the pattern `AshEnterprise.Quality.Suite` already uses. A journey also
carries a declared `version`. The hash is what the lock compares.

### 2. The governing rule

**A projection may show only what a passing run of the same journey version recorded.** A passing run is one in which
every step passed on its first attempt, against the declaration hash the lock names. A journey with no approved
passing run appears in no projection; it is not shown with a caveat. A figure is a figure a run captured, and a step
sentence is a sentence the run's declaration held.

| The journey, when it is… | Projection | Where it lives | Built |
|---|---|---|---|
| walked | a test, with trace and audit proof per step | `ash_browser_tests` (`AshBrowserTests.Journeys`) | yes |
| sealed | a run manifest; figures as stored bytes; a pass is evidence and a failure a finding | the host's sinks | the manifest; not the sinks |
| narrated | how-to and tutorial pages per locale, on the docs site and in a printed manual | `mix ash_journeys.export`; the site | the site pages; not the manual |
| shown in context | `/guide <journey>` in the Shell, the launcher and ACP | the host, through A2UI (`AshEnterprise.Guides`) | yes |
| answered | agent tools that list and cite journeys as "proven at commit X" | the host's tool surface | no |
| subtracted from the map | coverage: each surface and row action is documented, or waived with a reason | `AshBrowserTests.Ledger` | yes |

Runs are to export Cucumber Messages NDJSON (steps, attachments and outcomes), so that standard report tooling can
read them. The export is a projection and never a source. It is not built.

### 3. Publication is lock and approve

A run writes candidates and never publishes. `mix ash_journeys.approve <run>` copies the approved run manifests and
figures under `priv/journeys/<locale>/`, and writes `priv/journeys/journeys.lock.json` with each journey's declaration
hash, the browser build, and each figure's file and raster SHA-256. Approval refuses a run that is not passing in the
sense of section 2. `mix ash_journeys.impact <run>` compares a later run with the lock figure by figure, so a changed
figure is a change for a person to review, read as a hash diff.

Here, figures are approved only from the artifact of CI's "Journeys" job, which runs on the Chromium bundled with the
pinned Playwright release; the lock records that build.

`mix ash_journeys.lock --check` runs in `check`, `scripts/pre-ci` and CI, with no browser. It reads each approved run
through `AshJourneys.Lock.verify/6`, the gate every projection also passes through, and fails when the documentation
is older than its proof: the declaration's hash is not the approved run's, the lock pins another browser build, an
approved file or the lock entry is not what approval wrote (a hand edit to the lock cannot make another run current),
or a text or label resolves differently than the run recorded. It does not fail because a figure would look
different today; that is found by the next run and reviewed at approval.
This is the shape of the judgment lock (`priv/judgments/lock.json`, ADR 0039) and the paper layout lock (ADR 0068).

The projections read the lock and the approved files, never a run in progress:

- `mix ash_journeys.export` writes each approved journey as `docs/journeys/<locale>/<journey>.md`, with its figures in
  `site/src/assets/journeys/` named by digest and masked regions painted a neutral colour.
  `site/scripts/sync-docs.mjs` publishes them under `/docs/journeys/`, and a test fails when the committed pages
  differ from a fresh export.
- `AshEnterprise.Guides` compiles a journey's IR and its approved run into A2UI 1.0 basic-catalog messages (numbered
  steps as `Text`, figures as `Image`), validates them against the vendored schema before serving them, and serves
  each figure by the digest the lock records. Each guide is an entry in `AshEnterprise.Surfaces`
  (`/app/guide/<journey>`, opened by `/guide <journey>`), so the Shell, the launcher and ACP list it as they list any
  surface. A guide whose journey has no approved run in the reader's locale, or whose declaration is newer than its
  run, shows that it cannot be shown, and nothing else.

### 4. The packages, and the line between runtime and test

The declaration and every read over it are data, and execution happens only in tests and CI. That line is what lets
in-app help ship in a release while the browser runner stays test-only.

| Package | Holds | In a release? |
|---|---|---|
| `ash_journeys` | the DSL, verifiers and `Info`; the IR and its hash; the run manifest; the `World`, `Persona`, `EvidenceSink` and `FigureStore` behaviours; label resolution and the `journeys` Gettext extractor; the exporter; the `lock`, `approve`, `impact` and `export` tasks; `usage-rules.md` | yes, with no browser or Playwright dependency |
| `ash_browser_tests` | the journey runner, per-step capture and framing, a per-step span cursor in `Trace`, journey and `:undocumented` keys in `Ledger` | no; test-only, as before |
| the host | its journeys; `World` and `Persona` over its demo data; the guide pages (`AshEnterprise.Guides`, `AshEnterpriseWeb.GuideLive`); an `EvidenceSink` over its compliance store, a `FigureStore` over its evidence store, and `journey:` references in `docs/controls.json` (`AshEnterprise.Journeys.ControlReference`), which resolve only while the journey's approved run proves it | — |

- `ash_browser_tests` depends on `ash_journeys`, never the reverse.
- `ash_journeys` carries no compliance, evidence or document-rendering types. Control ids are opaque `metadata` that
  only the host's sink reads. An adapter for a document renderer lives in the host, or in an optional module that
  compiles only when that renderer is present.
- Per ADR 0070, a piece moves into `ash_journeys` only when it holds with no product noun; a second host's use is the
  signal to move host code down. The guide compiler is host code for that reason: one host uses it.

### 5. Evidence trust rules

1. **A run manifest records** the commit, journey version, declaration hash and locale; the **environment class**
   (`:test`, `:staging` or `:operated`); the browser and framing profile; and per step its status, attempts,
   correlation id, span ids, figure SHA-256 and highlight box, and the texts the run resolved.
2. **A pass after a retry is flaky and never evidence.** It is reported as flaky, it cannot be approved, and it
   counts toward neither documentation nor a control. A retry is an earlier attempt of the same run: CI passes its
   attempt number (`JOURNEYS_RUN_ATTEMPT`), and a local run is keyed on its commit, so a re-run job or a second
   `mix test` at one commit is a retry. A step's browser failures (a console error, page error or 5xx in any
   persona's context) fail the step, so a run the browser failed is never recorded as passed.
3. **Only `:operated` runs count toward a control's freshness.** A run against the test sandbox and fakes proves the
   code, not that the control operates in a deployment we run. The compliance store has no environment class today;
   it is added there and in the host's sink before any run is counted.
4. **Figures come only from the seeded world.** An `:operated` run records its manifest and never screenshots, until
   the erasure path (ADR 0024) covers figure bytes. No published figure shows a real person's data.
5. **Figure bytes are stored once, by hash.** The approved files are under `priv/journeys/`, named in the lock. The
   host's `FigureStore` (`AshEnterprise.Journeys.FigureStore`) keeps the audit copy: each figure as an immutable
   document version of kind `journey-figure`, each execution of it as one `playwright` run record, and its highlight
   as a region of that run; the stored bytes are the record (ADR 0067). It stores only bytes that hash to the lock's
   `file_sha256`. Playwright trace files are kept as hashes only.
6. **Verdicts reach compliance only through the host's sink**, on the template of `Audit.ChainVerifyWorker`: a pass
   records evidence with `method: :test` and `producer: "journey:<id>"`, and a failure upserts a `:noncompliant`
   finding. The host's sink is `AshEnterprise.Journeys.EvidenceSink`; nothing calls it yet, so no journey run is
   evidence yet.
7. **A step is proved by its audit rows, not by its spans.** Spans link a step to the audit rows its correlation id
   names; the audit row is the proof. The [ADR 0065 amendment](0065-signoz-and-glitchtip-observability-backends.md)
   states the rules.

### 6. Coverage, and waivers that someone wrote

`AshBrowserTests.Ledger` has a second axis beside "exercised": **documented**. Each declared surface and each
manifest row action appears in at least one journey, or carries a hand-written `{:undocumented, kind, id, reason}`.
The ledger's rules carry over unchanged: a waiver needs a reason, a stale waiver fails and a duplicate id fails.

**Waivers are never generated.** The host's e2e wiring already refuses generated waivers: "a waiver is meant to be a
decision someone made with a reason" (`test/support/e2e/surfaces.ex`). Coverage against the full surface registry is
reported as a number, the way that module reports adoption, and is not padded to look complete.

## Does it consume ActorContext?

Yes, in the ordinary way, and nothing bypasses it. A persona is a real seeded actor signed in through the host's own
sign-in, so every act in a run is an Ash action under ordinary policies, and its `ActorContext` is built once per
request as usual. The start-of-run check of each persona's door, when built, reads the same precomputed context.
The guide pages read only the
IR and the lock, which hold no tenant data, and are open to any signed-in person: a guide's surface has no door, and
its figures come from the seeded world. Showing a guide only to a viewer whose context reaches the journey's surfaces
would be a filter over the precomputed context, never a check that queries. Nothing here adds a grant, a `forbid_if`
or a bypass.

## Consequences

- A rename fails the build or the run instead of leaving the docs wrong: a reference that no longer exists fails
  verification, and a label or translation that changed fails `lock --check`, the guide and the export until a run
  that shows it is approved. Documentation can no longer be older than its proof without `check` saying so.
- One walk replaces several: the screenshot script, the walkthrough prose and the paths in `assets/e2e/` that a
  journey covers retire as journeys cover them.
- A journey run is slow (a real browser, often two contexts) and can flake. Under rule 5.2 flake costs coverage and
  evidence, never correctness, but a flaky tier produces little of either until it is stable. The CI job that runs
  journeys is advisory for that reason.
- Figures are deterministic only as far as Phase 1 measured. On one host and one Chromium build, two shoots gave
  byte-identical figures: CI attempts 1 and 2 of one run agreed on all 8 figures, a third CI shoot on a later commit
  matched the lock, and two local runs on one build agreed. The lock pins the build (Chromium 158.0.8127.18) and
  figures are compared by raster hash. Across hosts on that same build, 3 of 4 figures per locale were byte-identical;
  the fourth differed in one 8×11 pixel box, a sort-indicator glyph the browser draws from a system fallback font.
  Across builds (Chromium 151 against 158) every figure differed. So figures are approved from CI's artifact only,
  and a figure taken on a developer's machine is never compared with the lock.
- A figure shows no English in a French page by construction rather than by review: the browser job walks each
  journey once more in a pseudo-locale (`en_XA`, configured only under test), where every message the application
  translates is its msgid accented, and fails any word of ASCII letters left in a figured region outside its masks,
  with the text and the surface. The run is written under its own run id and is never approvable, since the journey
  declares no such locale. What it names as data (the product and organization names, a seeded person's email and
  creation time, a keyboard hint) is the host's list. Narration is covered separately: `--check-translated` fails
  a journey text with no translation in a declared locale.
- Each journey needs a seeded world, so demo data becomes part of the documentation's inputs.
- Journeys can only drive what the manifest describes. Until the manifest describes forms and wizard steps, a journey
  stops at tables and row actions.
- Hand-written how-to pages for a path a journey covers are replaced by the journey's page, not kept beside it.
  Reference and explanation pages stay as they are.
- Each projection is kept thin. A projection that needs data no run records is a sign the journey, not the
  projection, must change.

## Alternatives considered

- **Gherkin feature files as the source.** Gherkin gives a shared vocabulary, but it binds prose to code by regular
  expression, so a rename leaves the scenario reading correctly and failing to bind, or binding to the wrong step.
  Its documentation generators have been coupled to one binding framework: Pickles is discontinued, its maintainers
  say, because it was built around SpecFlow, which reached end of life. Steps here are references the compiler checks.
  Interchange is kept by exporting Cucumber Messages, the format Cucumber's own tooling reads.
- **Documentation first, with tests embedded in it** (Doc Detective, Concordion). The document is the master and
  instrumentation is annotated into it. That keeps prose primary, which this design also does, but the bindings are
  literal selectors and text with no model of the application, so a rename is found only when the page is run, and
  in-app help and evidence would have to be parsed back out of prose. Concordion's lesson is kept: the narration is
  written by a person, and the bindings sit beside it.
- **Publish every run's figures automatically.** It is the least work, and a changed figure would ship without anyone
  seeing it, whether the change was intended or a rendering artifact. Practitioners who keep documentation
  screenshots current from CI recommend reviewing a changed screenshot as an intended change rather than publishing
  it blindly. Lock and approve does that review, and the lock check keeps it from being skipped.
- **Journeys inside `ash_browser_tests`.** One package fewer, but that package is test-only and is never compiled
  into a release, so in-app help could not read the declaration.
- **A hand-written task library, as Screenplay does it.** The actor, task and question model is adopted, but tasks are
  declared as data over the application's own surfaces and actions, so they can be verified and projected, instead of
  written as code that only a test can run.

## Reversal

- **Dropping the rule** (letting projections show unproven content) means deleting the lock check from `check`,
  `scripts/pre-ci` and CI, and the approval gate; the declarations and the runner keep working, and docs pages become
  hand-maintained again.
- **Dropping journeys altogether** means deleting the host's journey modules, `priv/journeys/`, `docs/journeys/`,
  `site/src/assets/journeys/`, the guide pages (`AshEnterprise.Guides`, `AshEnterpriseWeb.GuideLive`,
  `AshEnterpriseWeb.GuideFigureController`, the `:guides` registry group and its entries) and the journeys exported
  directory in `site/scripts/sync-docs.mjs`; removing the `ash_journeys` dependency; and removing the runner and the
  journey keys from `ash_browser_tests`. The generated surface and row-action tests are unaffected. Evidence recorded
  by then stays in the compliance store, attributed to its `journey:<id>` producer, and stays readable.
- **Replacing the DSL with another source** (for example Gherkin) means writing a compiler from that source to the
  same IR. Every projection reads the IR, so none of them changes; the verifiers would have to be rebuilt over the new
  source's bindings.
