# Session handoff

Written 2026-08-14, at the end of the build session that created this repository.
Read this first in a new session, then `docs/manifesto/00-index.md`.

---

## 1. Where things stand

**`/home/lukegalea/ash_enterprise`** — **88 tests passing**, compiles clean with
`--warnings-as-errors`, `mix ash.codegen --check` clean, `mix release` builds in
`MIX_ENV=prod`.

**`/home/lukegalea/ash_strangler`** — **99 tests / 4 properties passing**,
steps 1–7 of its plan shipped. Standalone repo, **not vendored** into the app.

Both are now on GitHub under `lukegalea`, pushed 2026-08-14, **both private**:

- `github.com/lukegalea/ash_enterprise` — private, as intended permanently.
- `github.com/lukegalea/ash_strangler` — **private for now, intended to go
  public.** It was held back only because publishing an alpha extension before
  its first CI run is a bad first impression. Flip it once the GitHub Actions
  run on `master` comes back green: `gh repo edit lukegalea/ash_strangler
  --visibility public`.

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
(7 records, all written). Both are current.

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
3. **`ash_strangler` step 8** — the publication audit (§9.1 of the plan) is the
   only step left. **Steps 1–7 are shipped, 2026-08-14** (99 tests, 4
   properties): verifiers, view generation, the round-trip harness, `INSTEAD
   OF` triggers, the notification bridge, backfill + reconciler, and the
   `:read_from_new` reversal. All four phases generate SQL that has been
   executed, not merely inspected — including a full migrate / rollback /
   migrate cycle.

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
   Note the plan's own conclusion: the demo must run the dual-write step **both
   ways**, and **authentication cuts over first**, not last, because a single
   computed-but-writable mapping decides whether sign-in still works.
5. **Business process modelling** — `docs/plans/business-process-modelling.md`
   (955 lines). Recommends a token-based interpreter as an Ash domain driven by
   Oban, *not* a BPMN-conformant engine and *not* a JVM integration. Fully
   planned, no code.
6. **Known gaps, deliberately** — `docs/manifesto/07-what-we-do-not-have.md`:
   no WebAuthn or SAML, no approval-workflow extension, no retention/erasure
   story for the append-only audit log, no Dialyzer certainty.

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

Everything in §5 except the publication audit is committed and done:
`mix cdm.gen.resource`, the `Reference` domain, all six `ash_strangler` spikes,
and `ash_strangler` steps 1–7.

Two things, in this order:

> **1. Watch the first CI run** on `lukegalea/ash_strangler`. It has never
> executed — the workflow calls the org's shared `ash-ci.yml`, and the inputs
> (`postgres: true`, `ash_postgres: false`, `changelog-lint: false`) are
> reasoned but unproven. Then flip the repo public.
>
> **2. Consider `git_ops`.** `ash-ci`'s `changelog-lint` job actively *fails* a
> build that adds an `## [Unreleased]` section, because the org generates
> changelogs from conventional commits instead. The job is currently disabled
> with a comment. Adopting `git_ops` and dropping the Unreleased section would
> let it be re-enabled — worth deciding before 0.1.0 rather than after.

Then the reference app's own strangler demo (§5.4), which is where the package
gets exercised against a schema it did not grow up with — the plan's §4 warns
that the demo must run dual-write **both ways**, and that authentication cuts
over **first**, not last.

Opening line for a new session:

> Read `docs/HANDOFF.md`, then start the reference app's strangler demo
> (§5.4) — `ash_strangler` steps 1–8 are done and pushed.
