# Session handoff

Written 2026-08-14, at the end of the build session that created this repository.
Sections 1, 4, 5 and 7 were re-verified and corrected on 2026-08-18; §2, §3 and §6
are unchanged from the original.

Read this first in a new session, then `docs/manifesto/00-index.md`.

Two documents written after this one are now the better entry points for *what
the state is*, and this file is the better entry point for *what will waste your
time*:

- [`docs/QUESTIONS.md`](QUESTIONS.md) — the 28 enterprise questions and which
  ones have a shipped answer, generated from `roadmap.json` and CI-checked.
- [`docs/ROADMAP.md`](ROADMAP.md) — where the open and planned ones go, in what
  order, and the one rule every choice had to clear.

---

## 1. Where things stand

**`/home/lukegalea/ash_enterprise`** — **102 tests, 0 failures** (re-run
2026-08-18; this said 88 when written on 2026-08-14). Compiles clean with
`--warnings-as-errors`, `mix ash.codegen --check` clean, and
`mix ash_enterprise.roadmap --check` clean. `mix release` builds in
`MIX_ENV=prod`.

> ⚠️ **`mix credo --strict` exits non-zero on a clean tree**, and did so before
> the 2026-08-18 documentation work — so the CI credo step is red. The findings
> are two `Enum.map/2 |> Enum.join/2` calls and two cyclomatic-complexity
> warnings on `Mix.Tasks.Cdm.Gen.Resource.ash_type/2`. None is a correctness
> problem; all four are real and should be fixed rather than ignored.

**`/home/lukegalea/ash_strangler`** — **341 tests in 21 files** over ~12.7k
lines. Standalone repo, **not vendored** into the app — though
[ADR 0009](adr/0009-strangler-and-bpmn-are-first-party.md) now makes it a
first-party extension this repository is meant to depend on, which has not been
done yet.

**`/home/lukegalea/ash_bpmn`** — **202 tests in 10 files** over ~8.5k lines. It
did not exist when this file was written; see §5.5.

All three are on GitHub under `lukegalea`. Verified 2026-08-18:

- `github.com/lukegalea/ash_enterprise` — **public**, under an MIT `LICENSE` at
  the repository root. This file originally recorded it as "private, as intended
  permanently"; that was true on 2026-08-14 and is not true now. The vendored CDM
  corpus under `priv/cdm/schemaDocuments/` keeps its own CC-BY-4.0 terms —
  see `priv/cdm/ATTRIBUTION.md`.
- `github.com/lukegalea/ash_strangler` — **public**, not on Hex. Its CI was red
  on `main` for four consecutive runs and is **green as of 2026-08-18**: the
  typed-mapping DSL added a `backfill_interlock?` option without regenerating
  `.formatter.exs`, and `AshStrangler.Lens` specced `Ash.Query.Ref.t/0`, a type
  `Ash.Query.Ref` does not declare — which the shared workflow's
  `warnings: [:unknown]` turns into a build failure rather than a loose type.
- `github.com/lukegalea/ash_bpmn` — **private**, not on Hex.

`ash_enterprise` and `ash_strangler` both default to `main`. They were created on
`master` and renamed, because the shared `ash-ci` workflow triggers on `main`
only — on `master` it never ran at all, silently.

Four things the first CI runs found that local testing could not:

1. **No `.tool-versions`** — the shared workflow's `install-elixir` step reads
   it, so every compiling job failed instantly.
2. **`PGHOST` is set in CI** to the service-container name `postgres`, which
   only resolves for jobs running *inside* a container. The test config read it
   and every test failed with `non-existing domain`. The override is now
   `DB_HOST`; `PGHOST` is libpq's own variable and other tooling sets it.
3. **citext folding is collation-dependent** — see §3.
4. **`ash-ci`'s credo job cannot pass on a private repo.** It declares
   `permissions: security-events: write` and nothing else, which drops
   `contents: read`, so checkout 404s. Every `ash-project` repo is public, so
   upstream never hits it. This was the actual reason to go public rather than
   any judgement about readiness.

A secret scan before pushing came back clean: the only credentials in tracked
config are the standard Phoenix dev/test placeholders, `runtime.exs` reads
production values from the environment, and `.env` is gitignored.

### Phases, honestly

| Phase | State |
|---|---|
| 1. devenv environment | **done** |
| 2. App bootstrap, full dependency stack | **done** |
| 3. CDM corpus + resolvers | **done**, including `mix cdm.gen.resource` (added 2026-08-14, see §5) |
| 4. Platform base resource | **done**, including correlation ids and OTel |
| 5. Accounts / Security / Audit domains | **done**; the `Reference` domain (Currency, TimeZoneDefinition, LanguageLocale) was added 2026-08-14 as the generator's proof, see §5 |
| 6. Security engine + conformance suite | **done**, all three grant paths |
| 7–8. APIs + UI | **done** |
| 9–11. Skills, gates, manifesto, ADRs | **done** |

> ⚠️ The in-session task list still shows tasks 3, 5 and 8 as `in_progress`.
> That is stale bookkeeping, not outstanding work — except for the two genuine
> gaps named above.

---

## 2. Environment: things that will waste your time

Everything runs inside `devenv`. **Never invoke `mix` directly** — wrong Elixir,
and it writes to `~/.mix` instead of the project-local `MIX_HOME`.

```bash
devenv up -d                              # Postgres only
devenv shell -- mix test
devenv shell -- iex-server                # the app
devenv shell -- mix ash_enterprise.seed   # tenant + admin + privileges
```

Four traps, each of which cost time to find:

1. **The Postgres port is dynamic.** devenv shifts it when 5432 is taken (Docker
   here) but rewrites only `postgresql.conf`, *not* `$PGPORT`. `enterShell`
   reads it back from the conf. Never hardcode it.
2. **`MIX_ENV` must stay unset.** Exporting it makes `mix test` run in `:dev`, so
   `config/test.exs` never loads and the Ecto Sandbox pool is missing.
3. **Never run `mix phx.server` as a devenv process.** It holds the `_build` lock
   and blocks every other mix command, and process-compose restarts it.
4. **Long `mix` commands: run them backgrounded and poll**, don't pipe through
   `tail` — the pipe buffers and you see nothing until completion.

The `.claude/settings.json` codegen-drift hook is **written and verified but not
yet loaded** — the file did not exist when the session started, so the settings
watcher never picked it up. Open `/hooks` once, or restart, to activate it.

---

## 3. Findings that would be expensive to rediscover

These are the ones that cost real time and are not written in any upstream doc.

### Ash / Spark

- **Spark verifiers do not raise when a module is defined.** They run in
  `__verify_spark_dsl__` via `Module.ParallelChecker`, *after* compilation, in
  another process. A bad DSL surfaces as `warning: ** (Spark.Error.DslError)` and
  only fails a build through `--warnings-as-errors`. **`assert_raise` around a
  `defmodule` catches nothing** — a test written that way passes whether or not
  the verifier works. Call `verify/1` directly against `spark_dsl_config()`.
- **Ash validates required attributes *before* `before_action` hooks run.** A
  default set in a hook arrives too late and the action fails "… is required".
  Set defaults directly in `change/3`.
- **`Ash.Resource.Builder.build_calculation` output must be added to
  `[:calculations]`**, not `[:attributes]`. The wrong path surfaces as
  `key :primary_key? not found in %Ash.Resource.Calculation{}`.
- **Spark ≥ 2.7 requires `__spark_metadata__` on every entity target struct**, or
  compilation emits a deprecation warning per entity.
- **`prompt/2` is a macro in `AshAi.Actions`**, not a function in `AshAi`, and is
  not auto-imported by the extension.
- **`transition_state/1` takes the target *state*, not the action name.**
- **`starts_with` is not an Ash expression function.** Use ash_postgres `like`.
- **Expression calculations need built expression structs**, not raw AST.
  `quote` attaches `imports: [{2, Kernel}]` to `if`/`==` and Ash rejects it —
  it needs *its own* `if`, not Kernel's. Hand-built AST fails the same way. Use a
  module calculation unless you are prepared to depend on Ash internals.

### Postgres / AshPostgres

- **`citext` case folding is collation-dependent, so it is not portable.** It
  folds by calling SQL `lower()`, which follows the database's `LC_CTYPE`: under
  `C` only ASCII folds, under a UTF-8 locale Turkish dotted I and German ß fold
  too. **The same mapping therefore gives a different uniqueness answer on two
  servers** — which matters enormously for a migration, since a migration has
  two servers in it by definition. An Ash `identity` on a citext column may hold
  in development and not in production. Found when a test asserting the local
  `C` behaviour failed on CI's `postgres:16`. It never folds whitespace and
  never normalizes NFC against NFD, under any collation.
- **`AshPostgres.Extensions.Vector` is a Postgrex *type* extension, not an
  `installed_extensions` entry.** pgvector needs *both*: the string `"vector"` in
  `installed_extensions`, and `Postgrex.Types.define` referenced from the repo's
  `types:` config.
- **`text_pattern_ops` is mandatory** for a btree index to serve `LIKE 'prefix%'`
  under any non-C collation. Without it the index exists, looks right, and is
  never used.
- **Postgres cannot infer parameter types inside `substring()`** — cast every
  placeholder explicitly or Postgrex fails with "expected a binary, got 113".

### Ecosystem

- **`ash_a2ui` is not on hex** — git dependency. Add `:ash_a2ui` to
  `.formatter.exs` `import_deps` or the formatter rewrites its DSL into ordinary
  function calls. `createAshA2uiCatalog` is a **factory** taking the lit runtime
  as a dependency; a wrong-shaped call bundles fine and fails at runtime, so
  verify by executing it in node.
- **SaladUI cannot be used here.** It declares `igniter` as a *runtime* dep,
  which conflicts with our `only: [:dev, :test]` and would ship a codegen tool
  into production releases. ADR 0006.
- **`ash_events` generates the event log's attributes as private**, so an A2UI
  surface over it has no public fields to render.
- **`ash_json_api` serves its OpenAPI document with no `content-type` header**;
  `json_response/2` rejects it. Decode the body directly.
- **Verified against ash_authentication 4.14.1:** the `password` strategy does
  not upsert; `oauth2`/`oidc` **cannot be defined without** one (the transformer
  validates it); `UserIdentity` upserts unconditionally.
- **Tidewave silently breaks Clarity, and the symptom looks like Clarity's
  fault.** `Tidewave.maybe_inject_toolbar/1` injects its `<meta>` and `<script>`
  before the **last** `</head>` in the response body. Clarity inlines a ~5 MB JS
  bundle that contains the literal string `</head>`, so the injection lands
  *inside* that script and the next `</script>` truncates it. Clarity's
  JavaScript never runs and its LiveView socket never opens, so `/clarity` is a
  permanent splash screen. Found 2026-08-18 while capturing screenshots, and
  confirmed by counting: the response contains **two** `</head>` strings, the
  real one and one inside the bundle. **Fixed** — `lib/ash_enterprise_web/endpoint.ex`
  now skips the injection for `/clarity` paths only, verified by fetching both a
  Clarity page (no Tidewave markup) and `/` (Tidewave still present).
- **`/clarity` with no vertex crashes on connect** — `** (RuntimeError)
  attempted to live patch while mounting`, in a reconnect loop. Any URL naming
  both a vertex and a content id works, e.g.
  `/clarity/architect/application:ash-enterprise/ash-diagram-clarity-content-er-diagram`.
- **Clarity has no state-machine view**, despite `ash_state_machine` being in
  use. The content providers all live in `deps/ash_diagram/lib/ash_diagram/clarity_content/`
  — architecture, class, ER, policy diagram, policy simulation — and
  `ash_state_machine` ships no `Clarity.Content` module at all. Lifecycle
  diagrams come from `ash_diagram` directly, not from Clarity.
- **Chromium cannot rasterize in this sandbox.** `page.screenshot()` hangs
  indefinitely under system Chrome and every `--disable-gpu` / `--single-process`
  / `--headless=old` combination. Firefox and WebKit work. Every capture in
  `docs/screenshots/` from 2026-08-18 is Firefox at 1440×900,
  `deviceScaleFactor: 2`.

### The CDM corpus

- **The CDM contains no security or audit model at all** — no `SecurityRole`,
  `Privilege`, `Audit`, `PrincipalObjectAccess`, `FieldPermission`. Those come
  from the Dataverse table reference, which *is* maintained. Hence the hybrid
  corpus (ADR 0001).
- **`is.constrainedList` is declared in `foundations.cdm.json` but never used** by
  any entity, so the CDM cannot tell you what a picklist value means. All option
  sets and the state/status correlation come from the Dataverse docs.
- **`CdmEntity` is empty** — `extendsEntity` inherits zero attributes. The
  cross-cutting columns live in attribute *groups*.
- **`Organization` is 505 columns.** Hand-written, never generated.

---

## 4. Architecture, in one screen

The argument is `docs/manifesto/` (7 theses); the decisions are `docs/adr/`
(**19 records**). The split matters: **0001–0008 are `accepted` and describe code
that exists**; **0009–0019 are `proposed` and none of them is built.** They were
written early on purpose — a decision is cheapest to reason about, and cheapest to
reverse, while the alternatives are still fresh. Records 0009 onward carry one
extra mandatory section, `## Does it consume ActorContext?`, because that is the
single bar every one of them had to clear.

**`AshEnterprise.Platform.Resource`** is the base resource every resource uses.
It supplies ownership, provenance, lifecycle, concurrency, tenancy, audit, soft
delete, telemetry, policies and API exposure. Implemented as a Spark extension +
transformer, so inherited attributes stay introspectable (the ER diagram shows
them — asserted by test).

**Authorization is a pure union of three grant paths** — role/depth, sharing,
hierarchy — precomputed once per request into `ActorContext`. Two rules are
absolute and stated in `CLAUDE.md`: never `forbid_if` for row access, and a
policy check must never query.

**Ownership mirrors Dataverse's OwnershipType** (`:user_owned`,
`:business_owned`, `:organization_owned`, `:none`) and decides which depths
apply. The value per CDM resource is *scraped*, in
`priv/cdm/resolved/dataverse_*.json`, not guessed.

**Agents get the same actions and policies as everything else.** The `/agent`
console has the model *plan* (structured output, `tools: false`) and the human
*approve*; execution runs as the human. The whole flow is tested without an API
key, because only interpretation needs one.

---

## 5. What is genuinely not done

Ordered by how likely you are to want it.

1. ~~**`mix cdm.gen.resource`**~~ — **done, 2026-08-14.** `lib/mix/tasks/cdm.gen.resource.ex`
   reads a resolved corpus entity (CDM or Dataverse format), strips every
   attribute the platform base resource already supplies, maps the rest to Ash
   types with required-ness/max-length/description carried over, writes the
   resource, and creates or patches the target domain module and
   `config :ash_enterprise, ash_domains: [...]`. It does *not* guess ownership
   for a plain-CDM entity (no `dataverse.ownership_type` to scrape) or wire up
   `Lookup` relationships — both are left as an explicit `--ownership` flag and
   a commented placeholder column respectively, on purpose; see the task's
   moduledoc and the `cdm-adopt` skill for why those stay judgment calls.
2. ~~**The `Reference` domain**~~ — **done, 2026-08-14**, as the generator's
   proof. `Currency`, `TimeZoneDefinition` and `LanguageLocale` were generated,
   then hand-finished: a natural-key `identity` added to each (the generator
   does not propose identities), and `--no-tenant` used for the two genuinely
   global entities per the override `AshEnterprise.Platform.SystemAttributes`
   already documented for "time zones, locales" — `Currency` stays tenant-scoped
   since Dataverse requires `organizationid` on it. Covered by
   `test/ash_enterprise/reference/reference_test.exs`, which asserts the tenant
   scoping is actually enforced (same ISO code in two tenants: fine; same code
   twice in one tenant: rejected) rather than merely that the resources compile.
3. **`ash_strangler`** — the package is done; **adopting it here is not.** As of
   2026-08-18 it is **341 tests in 21 files**: verifiers (twelve, compile-time),
   view generation, the round-trip proof harness, `INSTEAD OF` triggers, the
   notification bridge, backfill + reconciler, the `:read_from_new` reversal, and
   a column-level lineage graph that already emits **OpenLineage** events. All
   four phases generate SQL that has been executed, not merely inspected —
   including a full migrate / rollback / migrate cycle.

   The mapping DSL was **replaced** after this file was first written: ten typed
   combinator entities, each a constructor whose reverse is *built* rather than
   an expression something tries to invert, per
   [ADR 0008](adr/0008-typed-invertible-legacy-mappings.md). If you read the
   original plan expecting the old grammar, read the ADR first.

   ⚠️ **Building it disproved the plan seven times.** Every one was found by
   running generated SQL rather than by rereading the document, and all are
   written up in §6.1 and §10:

   - **§6.1 — the load-bearing architectural decision was wrong.**
     `custom_statements` cannot carry DDL for a view-backed resource *at all*.
     `migrate? true` emits a `create table` for the view's own name so the view
     DDL fails against it; `migrate? false` stops the resource producing a
     snapshot, and custom_statements are read only from snapshots. No setting
     in between. Replaced by `migrate? false` (enforced, with the explanation
     in the error) plus `mix ash_strangler.gen.migration`. **Read this
     correction first** — the mechanism had been verified in isolation and the
     outcome had not, which is the same mistake as §10.1 and §10.12.
   - **§10.8** — its own mitigation ("one statement per resource containing all
     its DDL") is impossible; one statement is one command.
   - **§10.12** — a naive-timestamp cast was session-dependent, silently. Fixed
     by a required `from_zone:`.
   - **§10.13** — the primary-key declaration §5.4 prescribed broke every
     create; needs `generated? true`, now applied by a transformer.
   - **§10.14** — Ash's own casting diverges from what the legacy app writes,
     so "both write paths agree" is false by construction for some columns.
     The reconciler takes per-column normalization because of it.
   - **§2.4's `ecto_watch` verdict** — deliberately deviated from: adopting it
     would add `phoenix_pubsub` to a schema-mapping library and it still
     cannot synthesize an Ash notification, which is the only part that
     matters. The listener is built directly, zero new dependencies.

4. **The legacy schema demo** in this app — `docs/plans/ash-strangler-in-reference-app.md`.
   Still not started, and no longer optional:
   [ADR 0009](adr/0009-strangler-and-bpmn-are-first-party.md) makes
   `ash_strangler` a first-party extension, so the demo is what turns that claim
   into evidence rather than a README sentence. Note the plan's own conclusion:
   the demo must run the dual-write step **both ways**, and **authentication cuts
   over first**, not last, because a single computed-but-writable mapping decides
   whether sign-in still works.
5. **Business process modelling** — no longer "fully planned, no code".
   `docs/plans/business-process-modelling.md` (955 lines) became **`ash_bpmn`
   0.1.0**: **176 tests in 7 files** over ~7.9k lines, against real Postgres. A
   BPMN document compiled into an immutable versioned graph and executed by a
   token interpreter — one row per live branch, claimed optimistically — over
   Postgres and Oban, with an embedded bpmn-js designer; plus approvals as an
   `Ash.Resource.Change` droppable on any action, with a materialized candidate
   list, maker-checker exclusion by subtraction rather than `forbid_if`,
   delegation, and escalation timers that actually get cancelled.

   **The three blockers [ADR 0009](adr/0009-strangler-and-bpmn-are-first-party.md)
   named are closed, as of 2026-08-18, in the package rather than here:**

   - **It shipped no policies while running unauthorized internally** — every
     generated resource named `Ash.Policy.Authorizer` and contained no `policies`
     block, while the engine passed `authorize?: false` at roughly ninety call
     sites. Engine calls now carry `AshBpmn.Scope.engine/2` (actor, tenant and a
     private context flag) and each resource declares one bypass on
     `AshBpmn.Checks.AshBpmnInteraction`. That is not a stronger boundary than the
     option it replaced, and the module says so — it is a *named* one, which the
     ninety were not.
   - **Multitenancy was declared but not plumbed** — `AshBpmn.start_instance/2`
     bound `:tenant` to `_tenant` and dropped it, and the test tables had no
     `organization_id` for a test to have caught it with. The tenant now reaches
     the instance, tokens, work items and events, travelling in the Oban payload
     for the ones background workers create.
   - **A work item could not sit on the platform base resource** — the macros now
     take `:base` and `:base_opts`.

   **One composition rule came out of it**, and it is Ash's semantics rather than
   an oversight: a bypass short-circuits only the policies declared *after* it,
   and a base resource emits its policy set from `use`, ahead of anything
   `ash_bpmn` adds. Adopting it here therefore means either putting
   `AshBpmn.Checks.AshBpmnInteraction` at the top of
   `AshEnterprise.Security.Policies`, or setting `config :ash_bpmn, engine_actor:`
   to a `SystemActor` that policy set already bypasses. ADR 0009 states the
   trade-off between them.

   **What is not done is wiring it in here**, which is now a composition task
   rather than an authorization one.

   It also depends on raw `oban` rather than `ash_oban`, and on neither
   `ash_state_machine` nor `ash_events`, so it does not compose with this
   repository's audit layer for free. And it declares `phoenix_live_view` as a
   *runtime* dependency, because the designer ships with it.
6. **Known gaps, deliberately** — `docs/manifesto/07-what-we-do-not-have.md`,
   now twelve entries, five of which have a decision recorded in `docs/adr/` and
   seven of which do not: no WebAuthn or SAML, no retention or erasure story for
   the append-only audit log, no Dialyzer certainty, no i18n for content, no
   deployment guide, and **no column-level security actually declared** — that
   last one is new, and it is the one place a manifesto claim had run ahead of
   the code. The scoreboard version is [`docs/QUESTIONS.md`](QUESTIONS.md).

---

## 6. Conventions to keep

- **Commit messages explain *why*, and name bugs found by testing.** That is
  where most of the hard-won knowledge in this repo lives; `git log` is worth
  reading.
- **Every claim in docs is verified or marked unverified.** Several things in the
  original research turned out wrong and were corrected in place — do the same
  rather than leaving a doc knowingly stale.
- **Prefer named actions over generic `:update`.** The audit log records the
  action name, so `assign_to_business_unit` tells a reader what happened.
- **Tests assert the thing that must *not* happen**, especially in security. Every
  way to get authorization wrong makes it more permissive and none of them raise.
- **When something is missing, say so in the doc rather than working around it
  silently.** The A2UI audit surface was attempted, dropped, and the reason
  recorded.

---

## 7. Suggested next session

The forward plan now lives in two documents of its own —
[`docs/ROADMAP.md`](ROADMAP.md) sequences it, [`docs/QUESTIONS.md`](QUESTIONS.md)
scores it — and what follows is that sequencing rather than a competing list.

> **1. Adopt `ash_bpmn` and `ash_strangler` here.** This is first for one reason,
> and it is not that it is the largest: it is the only item where the claim is
> ahead of the code, which is the one kind of debt this repository refuses to
> carry. The three `ash_bpmn` gaps
> [ADR 0009](adr/0009-strangler-and-bpmn-are-first-party.md) named were closed
> upstream on 2026-08-18 (§5.5), so what is left is composition: add both to
> `mix.exs`, map one legacy table through `ash_strangler`, and put one approval
> behind `ash_bpmn` on a resource that uses `AshEnterprise.Platform.Resource`.
>
> Decide one thing on the way in. A bypass in Ash short-circuits only the
> policies declared *after* it, and a base resource emits its policy set from
> `use` — so either `AshBpmn.Checks.AshBpmnInteraction` goes at the top of
> `AshEnterprise.Security.Policies` (the engine then keeps the human actor, so
> ownership and the audit entry still name the person who approved) or
> `config :ash_bpmn, engine_actor: {AshEnterprise.Platform.SystemActor, :system, []}`
> reuses the `SystemActor` bypass already there, at the cost of attributing every
> engine write to it. **The first is preferable** for exactly the reason the audit
> log exists. Doing either, with a working approval behind it, is what moves ADR
> 0009 from `proposed` to `accepted`.
>
> The `ash_strangler` demo (§5.4) is the other half of the same item, and the
> plan's warning stands: dual-write runs **both ways**, and authentication cuts
> over **first**, not last.
>
> **2. Then the rest of priority 1**, in the order
> [`docs/ROADMAP.md`](ROADMAP.md) argues rather than in ADR number order:
> ingestion ([ADR 0010](adr/0010-meltano-for-ingestion.md)) before lineage
> ([ADR 0012](adr/0012-openlineage-and-marquez.md)), because you cannot trace
> provenance for data that arrived by hand; and the integration hub
> ([ADR 0011](adr/0011-nango-as-integration-hub.md)) alongside rather than after,
> because it answers a different question — systems you talk to, not data you
> pull.
>
> **3. Consider `git_ops`.** Unchanged from the original list, and still
> undecided. `ash-ci`'s `changelog-lint` job actively *fails* a build that adds
> an `## [Unreleased]` section, because the org generates changelogs from
> conventional commits instead. The job is currently disabled with a comment.
> Adopting `git_ops` and dropping the Unreleased section would let it be
> re-enabled — worth deciding before 0.1.0 rather than after.

One thing that blocks nothing but should not be discovered twice: **`ash_strangler`'s
CI was red on `main` for four consecutive runs**, from `32057721812` to
`32065066215` (2026-08-17). This file once recorded it as "fully green", which was
written before the first run had ever executed. It is green as of run
`32184205780` (2026-08-18); the two failures were a `.formatter.exs` that had not
been regenerated after the typed-mapping DSL added an option, and a spec naming
`Ash.Query.Ref.t/0` — a type `Ash.Query.Ref` does not declare, which the shared
workflow's `warnings: [:unknown]` fails the build over rather than degrading to
`any()`.

Opening line for a new session:

> Read `docs/QUESTIONS.md` and `docs/ROADMAP.md`, then `docs/HANDOFF.md` §3, and
> start on [ADR 0009](adr/0009-strangler-and-bpmn-are-first-party.md) — adopting
> `ash_bpmn` and `ash_strangler` here. Their side of it is done; this side is not.
