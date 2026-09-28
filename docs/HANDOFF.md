# Session handoff

First written 2026-08-14. Rewritten 2026-09-28: the sections that described
*current state* went stale within weeks (a test count, an ADR count, a "next
session" that shipped long ago), so they are now pointers to the documents that
are kept current by a gate or by the work itself. What stays here is what will
waste your time and what is expensive to rediscover.

Read this first in a new session, then `docs/manifesto/00-index.md`.

---

## 1. Where things stand

This file no longer records state. Look here instead:

| Question | Where it is answered, and what keeps it current |
|---|---|
| Which enterprise questions have a shipped answer? | [`QUESTIONS.md`](QUESTIONS.md), generated from `roadmap.json`; `mix ash_enterprise.roadmap --check` fails CI if it drifts, and refuses a question asked twice |
| What comes next, and in what order? | [`ROADMAP.md`](ROADMAP.md), generated from the same source |
| Which controls the evidence satisfies | [`COMPLIANCE.md`](COMPLIANCE.md), generated from `controls.json` through the same gate |
| What was decided, and which decisions are built | [`adr/README.md`](adr/README.md): the index and the status legend |
| What is deliberately missing | [thesis 7](manifesto/07-what-we-do-not-have.md) |
| Which agent lanes are working in this repo | `.agents/COORDINATION.md` |
| The capstone demo's storyline | [`capstone/storyline.md`](capstone/storyline.md) |
| The System One work (model judgments) | [`plans/system-one.md`](plans/system-one.md) and [thesis 8](manifesto/08-models-observe-declarations-decide.md) |

Verified on 2026-09-28, and dated so that a reader can tell when they stop being
true:

- **330 tests, 0 failures** under `devenv shell -- check`, which also runs
  `--warnings-as-errors`, `mix ash.codegen --check`, `mix credo --strict`,
  `mix ash_enterprise.roadmap --check`, the iron-laws judge
  (`docs/IRON-LAWS.md`) and the EXTRA_DOCS reference check. CI runs
  the same gate, plus a `cold-clone` job that fetches every dependency with no
  credentials.
- **48 ADRs**, 0001 to 0048. The status split is in
  [`adr/README.md`](adr/README.md) rather than here.
- **Eight theses** in [`manifesto/`](manifesto/00-index.md).
- **Ash comes from hex.** The earlier pin to a fork of Ash is gone, and so is
  the config flag it existed for.
- **Every first-party package is a public GitHub dependency** tracking its own
  `main`, with the SHA pinned by `mix.lock`: `ash_a2ui`, `ash_strangler`,
  `ash_bpmn`, `ash_decisions`, `ash_rules`, `ash_compliance` (which brings
  `ash_events_projections`), and `ash_agent_tools` (dev only). `mix.exs` says
  why there is no `ref:`.
- **`ash_strangler`, `ash_bpmn` and `ash_decisions` are adopted here**, which is
  what moved [ADR 0009](adr/0009-strangler-and-bpmn-are-first-party.md) to
  `accepted`. The 2026-08 plan that put this adoption first is done.

---

> §2 and §3 were written between 2026-08-14 and 2026-08-19 and have not all been
> re-verified since. Each entry names what it was verified against; check before
> relying on a version-specific one.

## 2. Environment: things that will waste your time

Everything runs inside `devenv`. **Never invoke `mix` directly** — wrong Elixir,
and it writes to `~/.mix` instead of the project-local `MIX_HOME`.

```bash
devenv up -d                              # Postgres only
devenv shell -- mix test
devenv shell -- iex-server                # the app
devenv shell -- mix ash_enterprise.seed   # tenant + admin + privileges
```

Five traps, each of which cost time to find:

1. **The Postgres port is dynamic.** devenv shifts it when 5432 is taken (Docker
   here) but rewrites only `postgresql.conf`, *not* `$PGPORT`. `enterShell`
   reads it back from the conf. Never hardcode it.
2. **`MIX_ENV` must stay unset.** Exporting it makes `mix test` run in `:dev`, so
   `config/test.exs` never loads and the Ecto Sandbox pool is missing.
3. **Never run `mix phx.server` as a devenv process.** It holds the `_build` lock
   and blocks every other mix command, and process-compose restarts it.
4. **Long `mix` commands: run them backgrounded and poll**, don't pipe through
   `tail` — the pipe buffers and you see nothing until completion.
5. **The iron-laws judge runs under `MIX_ENV=dev`** even inside `mix precommit`,
   because `ash_agent_tools` is a dev-only dependency. `scripts/iron-laws.sh`
   sets it; do not "fix" that by exporting `MIX_ENV` (trap 2).

The codegen-drift hook (`.claude/hooks/check-ash-codegen.sh`, wired in
`.claude/settings.json`) reports drift only when the check actually ran and said
so. Any other failure is reported as "the check could not run", which is not a
reason to generate; `CLAUDE.md` says why.

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

The argument is `docs/manifesto/` (eight theses); the decisions are `docs/adr/`,
whose README carries the index and what each status means. In short: a record
marked `accepted` describes code that exists, `accepted, not built` is a decision
taken with no code yet, and `proposed` is neither. Records 0009 onward carry one
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

## 5. What is not done

Not listed here any more: [`QUESTIONS.md`](QUESTIONS.md) scores every open and
partial answer, [`ROADMAP.md`](ROADMAP.md) orders them, and
[thesis 7](manifesto/07-what-we-do-not-have.md) names the gaps kept on purpose.
A list in this file would be a fourth copy, and the first to go stale.

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

---

## 7. Starting a session

Opening line for a new session:

> Read `docs/HANDOFF.md` §2 and §3, then `docs/manifesto/00-index.md`. Check
> `.agents/COORDINATION.md` for active lanes, and run `git fetch` and
> `gh pr list` before assuming anything is unstarted: this repository runs
> long-lived branches, and `main` is not the whole state of the project.
