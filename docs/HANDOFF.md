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
3. **`ash_strangler` steps 5–8** — listener/notifications, backfill/reconciler,
   the `:read_from_new` reversal, and a **step 8 added 2026-08-14: audit the
   repo against the ecosystem's conventions for third-party extension
   packages** before publishing. That checklist is researched and written up as
   **§9.1 of the plan** — the headline is that extensions do not hand-roll CI,
   they call `ash-project/ash/.github/workflows/ash-ci.yml` via
   `workflow_call`, and that `ash_credo` is a *consumer*-facing tool which
   extension repos do not run on themselves (the plan previously said
   otherwise; corrected in place).
   Steps 1–4 are **shipped, 2026-08-14** (46 tests, 4 properties):

   - **1, verifiers.** Unchanged.
   - **2, view generation.** `AshStrangler.Sql.View` builds the `CREATE VIEW`
     plus the `{:uuid_v5, ...}` expression index from the mapping;
     `AshStrangler.Transformers.DeriveStatements` injects them into
     `[:postgres, :custom_statements]`, so `mix ash.codegen` picks them up like
     any other schema change. No-op for a resource with no strangler mapping or
     not on `AshPostgres.DataLayer`.
   - **3, the round-trip harness.** Real Postgres, no mocks. It installs the
     fixture schema by *executing the generator's own output*, so the golden
     tests assert what the generator says and the round-trip tests assert that
     what it says runs. `AshStrangler.KeyDerivation` makes the key strategy a
     pure Elixir function asserted byte-identical to Postgres's
     `uuid_generate_v5` over generated inputs.
   - **4, `INSTEAD OF` triggers for `:dual_write`.** `AshStrangler.Sql.Triggers`
     generates insert/update/delete functions and triggers **only where the
     mapping requires them** (§10.2's trade), each re-reading the stored row
     rather than returning `NEW` (§10.1), and raising with the mapping's own
     `because:` text when something writes a `writable? false` attribute.
     §10.12's `from_zone:` was resolved first, as planned — the write path
     needs the exact inverse conversion, and dropping it is caught only by the
     test that shifts the session zone.

   All six spikes in §11 of the plan were answered the same day: `ecto_watch`
   can watch an arbitrary relation in a non-default schema via its map-form
   `schema_definition` — no Ecto schema module required, verified by reading
   `WatcherOptions.SchemaDefinition.new/1`; and a synthesized
   `Ash.Notifier.Notification` with `changeset: nil` does not degrade
   gracefully, it **raises** `KeyError` the moment a topic template uses
   `:_pkey`, `:_tenant`, or (for update/destroy) any plain attribute key —
   reproduced directly against `ash` 3.31.3. A *minimal* synthesized changeset
   (`resource`/`data`/`to_tenant`/`action_type`, no real changeset construction)
   fixes it, verified the same way.

   ⚠️ **Building steps 3 and 4 disproved the plan four times**, each found by
   executing generated SQL rather than rereading the document. All four are
   written up in §10 and all four are now fixed or corrected in place:

   - **§10.12** — `cast: :timestamptz` on a naive legacy column read the value
     in the *session's* `TimeZone`, silently, so the same row was 10.5 hours
     apart on two connections. Fixed by a required `from_zone:`, which
     generates `AT TIME ZONE` and is refused if absent
     (`VerifyTimestampZones`).
   - **§10.8** — its own central mitigation ("one statement per resource
     containing all of its DDL") is impossible: one statement is one
     `execute()` is one prepared statement is **one command**. Multi-command
     statements fail at migrate time with `42601`.
   - **§10.13** — the primary-key declaration §5.4 prescribed breaks *every*
     create with `attribute id is required`. Needs `generated? true`, applied
     by a transformer rather than asked of the user.
   - **§10.14** — `Ash.Type.CiString` trims by default, so a value written
     through Ash differs from the same value written by the legacy app. Not
     fixable and not a defect, but it makes "both write paths agree" false by
     construction for some columns. **The reconciler (step 6) must know this
     before its first run**, or it reports a wall of false positives, which is
     how a drift detector gets switched off.
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

`mix cdm.gen.resource` and the `Reference` domain (§5.1–5.2), all six
`ash_strangler` spikes (§5.3, §11 of the plan), and `ash_strangler` steps 1–3
(verifiers, `:read_from_legacy` view generation, the round-trip harness) are
committed and done.

Highest value next:

> Build `ash_strangler` step 5 in `/home/lukegalea/ash_strangler`: the listener
> that bridges legacy writes into `Ash.Notifier.Notification`s. Spike 6 already
> settled the hard part — the bridge **must** synthesize a minimal changeset
> (`resource`/`data`/`to_tenant`/`action_type`) or `Ash.Notifier.PubSub` raises
> `KeyError` on any topic using `:_pkey`, `:_tenant`, or an update/destroy
> attribute key. Spike 5 settled the other half: `ecto_watch` can watch
> `legacy.users` directly via its map-form `schema_definition`, so this is an
> integration, not a reimplementation.
>
> Step 6 (backfill + reconciler) is the one to think about hardest, for two
> reasons already recorded: pgroll's flag-column finding (§6.4) and §10.14's
> divergence, which will otherwise make the reconciler cry wolf on day one.

Then, before publishing, **step 8**: work the §9.1 checklist. The two items
with the most leverage are `mix spark.cheat_sheets` (the package currently
ships no DSL documentation at all, which for a DSL package is the conspicuous
gap) and adopting the shared CI workflow, which brings a dozen checks at the
cost of one file.

Opening line for a new session:

> Read `docs/HANDOFF.md`, then build `ash_strangler` step 5 — the notification
> listener — in `/home/lukegalea/ash_strangler`.
