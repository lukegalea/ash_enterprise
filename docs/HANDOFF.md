# Session handoff

Written 2026-08-14, at the end of the build session that created this repository.
Read this first in a new session, then `docs/manifesto/00-index.md`.

---

## 1. Where things stand

**`/home/lukegalea/ash_enterprise`** — 18 commits (plus `mix cdm.gen.resource` and
the `Reference` domain added 2026-08-14, not yet committed), **88 tests
passing**, compiles clean with `--warnings-as-errors`, `mix ash.codegen --check`
clean, `mix release` builds in `MIX_ENV=prod`.

**`/home/lukegalea/ash_strangler`** — 1 commit, 13 tests passing. Standalone repo,
**not vendored** into the app. Neither repo has a remote; nothing is pushed.

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
3. **`ash_strangler` steps 2–7** — view generation, triggers, backfill,
   reconciler. Step 1 (verifiers) is shipped. Two spike questions still precede
   step 2: whether `ecto_watch` can install triggers in a non-default schema, and
   what `Ash.Notifier.PubSub` does with a synthesized notification that has no
   changeset. See §11 of the plan.
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

`mix cdm.gen.resource` and the `Reference` domain (§5.1–5.2) are done but
**uncommitted** — review the diff and commit it first.

Highest value after that:

> Continue `ash_strangler` at step 2 — but answer the two remaining spike
> questions first; the plan is explicit that they precede it, and the last
> spike reversed a design decision.

Opening line for a new session:

> Read `docs/HANDOFF.md`, then continue `ash_strangler` at step 2 — after
> answering the two spike questions §11 of the plan says precede it.
