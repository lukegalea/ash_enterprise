# AshStrangler — implementation plan

> **Status: DEFERRED.** Not started, not scheduled. This is a design document for a *standalone open-source package*
> that would live outside this repository. It does not begin until the current phases (Organization/tenancy, hierarchy
> security) are complete. Written now because the design questions are cheap to answer on paper and expensive to
> answer in code, and because [§10](#10-what-is-genuinely-hard) contains findings that are true whether or not the
> package is ever built.
>
> Companion: [`ash-strangler-in-reference-app.md`](ash-strangler-in-reference-app.md) — how this repository would
> demonstrate it, and the conflicts that surfaces.

---

## 1. The problem, stated concretely

A team runs a Rails, Django, PHP or Node application against a Postgres database that has accumulated fifteen years of
schema. They want to move to Ash, and they cannot stop the world to do it. The database must stay up, the old
application must keep working, and the migration must be reversible at every point because it will take eighteen
months and somebody will be on call throughout.

The mechanics for this are known and unglamorous: **expand / migrate / contract**, otherwise called parallel change.
Add new structure additively; dual-write; move reads; drop the old. In Postgres the compatibility layer during the
middle phase is a view plus `INSTEAD OF` triggers — a view named for the old shape, defined over the new tables, with
triggers translating writes back. This is not novel. It is what pgroll and Reshape generate internally.

What does not exist is a way to **declare the mapping once** and have the view SQL, the trigger SQL, the reverse
trigger SQL, the notification plumbing, the backfill script, and the reconciliation query all derived from it. Today
that mapping lives in four places — a migration, a trigger function, an application model, and a runbook — and they
drift. The trigger functions in particular become, in one practitioner's phrasing, an undocumented and untested second
codebase.

Ash is unusually well-placed to fix this, because Ash resources are already a machine-readable description of the
target shape. The mapping from legacy to modern is the only piece missing, and it is small.

**Who this is for**, specifically:

- Teams adopting Ash on top of an existing Postgres database, not greenfield. This is the majority of real adoptions
  and the ecosystem's documentation for it (`mix ash_postgres.gen.resources`, "working with existing databases")
  stops at "here are resources over your current tables" — which is the *start* of the problem, not the end.
- Teams that need the old application to keep running against the old shape while the new one runs against the new
  shape, in the same database.
- Teams that need an auditable record of what the compatibility layer actually is, because a regulator or a security
  review will ask.

**Who this is not for.** If the modern schema will live in a different database or a different service, this is the
wrong tool and CDC (Debezium, or a WAL-reading Elixir library) is the right one. The entire design here rests on one
database and therefore one transaction. Cross-database consistency is a different problem with a different answer,
and the package should say so in its README rather than growing toward it.

## 2. Prior art

Verified 2026-08-13. We prefer adopting to building, so this section is written to try to kill the idea. It does not
quite succeed, but it removes about a third of the proposed scope.

### 2.1 The Elixir/Ash ecosystem

| Package | Status (2026-08-13) | What it is | Overlap |
|---|---|---|---|
| [`ecto_watch`](https://github.com/cheerfulstoic/ecto_watch) | **1.1.0**, Nov 2025; 108k downloads; 248 stars; active | Installs Postgres triggers + `pg_notify` at boot, one listener per watcher, rebroadcasts as `Phoenix.PubSub`. Keyed on **Ecto schemas** | **Substantial.** Does the notify pillar, competently, already |
| [`ash_replicant`](https://hex.pm/packages/ash_replicant) | 0.4.0, Aug 2026; repo 5 weeks old; 0 stars | Logical decoding (`pgoutput`) → AshPostgres resources; effect-once, SCD2 mirroring. **Explicitly no triggers, no views** | None. Mirroring, not mapping |
| [`walex`](https://github.com/agoodway/walex) | 4.8.0, May 2026; 368 stars; active | WAL-based CDC with durable slots. No Ash integration | None |
| [`cainophile`](https://github.com/cainophile/cainophile) | 0.1.0, **2019**; 18 commits total; dormant | Early Elixir logical decoding | None. Do not build on it |
| `ash_events` / `ash_paper_trail` | current | Application-level audit | None (and they are what the legacy writes bypass) |

`hex.pm` search for `strangler` returns **zero packages**. Enumerating ~120 packages that depend on `ash` turns up
nothing addressing legacy schema mapping, updatable views, or expand/contract.

**`ecto_watch` is the finding that changes the plan.** It is mature, adopted, and does trigger → `pg_notify` →
`Phoenix.PubSub` well. Reimplementing it would be waste. The only defensible reason to write a listener here is the
*Ash-specific* part — re-reading through Ash so policies, calculations and tenancy apply, then dispatching a real
`Ash.Notifier.Notification` so downstream consumers cannot distinguish a legacy write from an Ash one. That is a thin
layer, and it should be built *on* `ecto_watch` if its trigger installation can be pointed at arbitrary relations, or
as a clearly-scoped ~200-line module if not. Either way, **notifications are no longer a pillar of this package**;
they are an integration.

### 2.2 What AshPostgres already does

More than the source documents assumed, and it moved recently.

- **A resource can point at a view today.** `AshPostgres`'s own front page says, verbatim, *"Use this to persist
  records in a PostgreSQL table or view."* `table` is a relation name passed to Ecto; nothing checks `relkind`.
- **`mix ash_postgres.gen.resources --include-views`** was added in
  [PR #748](https://github.com/ash-project/ash_postgres/pull/748), merged 2026-05-14. It introspects
  `pg_class.relkind IN ('r','v','m')` and emits resources for views and materialized views with `migrate? false`,
  `defaults [:read]`, `require_primary_key? false` where there is no PK, and a `# TODO: Migrations need to be handled
  manually for views.` comment. Unique indexes on matviews become Ash identities.
- **The [existing-database guide](https://ash-postgres.hexdocs.pm/set-up-with-existing-database.html) is a three-step
  quickstart**: point the repo at the database, run `gen.resources --tables`, split across domains. It does not
  mention views, triggers, dual-writing, or migration strategy.
- **The DSL has no view, trigger, or notify constructs.** The only escape hatch is `custom_statements`, whose own
  docstring warns that ordering is not inferred.

So the ecosystem's position is: *view-backed resources are supported and assumed read-only; generating the view, making
it writable, and managing the transition are yours.* That is exactly the gap, and it is a narrower gap than it was
before May 2026 — the read-only half is now scaffolded for you.

### 2.3 Outside Elixir

| Tool | Status | Mechanism | Why it does not cover this |
|---|---|---|---|
| [**pgroll**](https://github.com/xataio/pgroll) | 0.16.2, May 2026; 6.5k stars; Go; Apache-2.0; very active | **Exactly our mechanism**: versioned schemas of views over physical tables, backfill, sync triggers, instant rollback | Evolves *your own* schema through a fixed operation vocabulary (`add_column`, `rename_column`, `change_type`, …). No concept of "legacy relation → desired model". Its `raw_sql` op is documented as forfeiting every guarantee that makes pgroll worth using: *"pgroll is unable to guarantee that raw SQL migrations are safe"* |
| [**Reshape**](https://github.com/fabianlindfors/reshape) | 0.9.3, Aug 2026; 1.8k stars; Rust; active | Same idea | Same limitation |
| [**pgschema**](https://github.com/pgplex/pgschema) | ~1k stars; young; Go | Terraform-style declarative diff/plan/apply | No expand-contract machinery, no mapping |
| [**Atlas**](https://github.com/ariga/atlas) | 8.6k stars; active | Schema-as-code, 16 ORM loaders | **Views, functions and triggers are paid-tier features.** No Elixir loader |
| **Sqitch** / **Flyway** | 1.6.1 / 12.7.0; both active | Ordered versioned migrations | Not relevant to this problem |
| [**Sequin**](https://github.com/sequinstream/sequin) | 2.2k stars; **written in Elixir** | Postgres CDC → sinks, with exactly-once and resumable/partial backfills | Read-side only, and a standalone service rather than a library. **Its backfill and watermark design is the thing to copy** |
| **Debezium** | current | WAL → Kafka; Red Hat's canonical strangler-fig reference | Solves change propagation, not schema mapping; requires Kafka |
| `postgres_fdw` tooling | — | Cross-*database* bridging | No tool packages FDW into a strangler workflow. Wrong axis: we are same-database |

pgroll and Reshape are the important entries because they **validate the mechanism and refute the scope**. Both are
healthy, both prove that views-plus-triggers-plus-backfill is production-grade, and neither can express a
legacy→modern mapping. Neither is consumable from Elixir except by shelling out to a binary and handing it JSON.

"Views-first schema" as a productized tool category **could not be found to exist**. The pattern is well documented as
folklore — Percona and Hasura both write about updatable views plus `INSTEAD OF` for low-downtime change — and nobody
ships a tool for it in any language.

### 2.4 Verdict

A new package is justified, on a **narrower scope than the source documents propose**:

- **Justified and unprecedented:** declarative legacy→Ash mapping as a Spark DSL, and generation of *writable* views
  with `INSTEAD OF` triggers wired to Ash resources. No tool in any language productizes the second one.
- **Justified but should be borrowed, not invented:** backfill and reconciliation. Copy Sequin's watermark
  coordination and pgroll's expand-contract lifecycle rather than designing either.
- **Not justified:** trigger → notify → PubSub plumbing. `ecto_watch` has it. Integrate or wrap; do not rebuild.
- **Not justified:** the `legacy_api` HTTP layer from `docs/AshStrangler.md`. Different package, and
  `reverse_proxy_plug` plus hand-written controllers already covers it.

The uncomfortable version of the verdict: **the two most valuable pieces (§6.3 verifiers, §6.4 pre-flight check) are
also the two that need no SQL generation at all.** §11 is built around finding out whether the rest earns its risk.

## 3. Scope

**In scope.**

1. A declarative mapping from a legacy relation (or a small join of them) to an Ash resource's attributes.
2. Derivation of the compatibility DDL — view, `INSTEAD OF` triggers, `AFTER` notify triggers — from that mapping,
   emitted through AshPostgres's existing `custom_statements` so it lands in ordinary generated migrations.
3. A phase model: one declaration on the resource selects which artifacts exist, and moving through the phases is a
   one-word edit plus a generated migration.
4. Pre-flight checking: run the assertions the target resource makes (`allow_nil?: false`, `identity`, type
   coercibility) against the legacy data *before* anything is generated.
5. Backfill and reconciliation tooling: batched, resumable, and with the drift check available both as a scheduled job
   and as a test assertion.
6. Notification *bridging* — legacy writes become `Ash.Notifier.Notification` structs so LiveView, GraphQL
   subscriptions and PubSub consumers cannot tell where a change came from. Bridging only: the trigger-and-listen
   plumbing underneath comes from `ecto_watch` (§2.1), not from here.

**Out of scope, deliberately.**

- **Trigger → `pg_notify` → PubSub plumbing.** `ecto_watch` 1.1.0 does it, is adopted, and is maintained. Rebuilding
  it would be the most visible part of the package and the least defensible.
- **CDC / logical replication.** Different problem, different guarantees. Named as the alternative in the README, with
  `walex` and `ash_replicant` as the Elixir-side pointers.
- **Serving the legacy HTTP API.** The `legacy_api` idea in `docs/AshStrangler.md` — generating Phoenix controllers
  that emit the old JSON shape — is a genuinely good idea and a *different package*. Mixing an HTTP concern into a
  schema-mapping extension makes both harder to reason about. `reverse_proxy_plug` plus hand-written controllers
  already covers it adequately; the derivation win there is much smaller than at the data layer.
- **Generic schema evolution.** This is not a migration tool for schemas you already own. `mix ash.codegen` does that.
- **Non-Postgres data layers.** The mechanism *is* Postgres.
- **Automatic decomposition of computed mappings.** `first_name || ' ' || last_name → full_name` is not invertible
  and the package must not pretend otherwise. See §5.3.

## 4. Package shape

```
ash_strangler/
  lib/ash_strangler.ex                      -- the extension entry point
  lib/ash_strangler/resource.ex             -- Spark.Dsl.Extension: the `strangler` section
  lib/ash_strangler/info.ex                 -- generated introspection
  lib/ash_strangler/sql/                    -- SQL generation, one module per artifact
      view.ex  insert_trigger.ex  update_trigger.ex  delete_trigger.ex  notify_trigger.ex
  lib/ash_strangler/transformers/
      derive_statements.ex                  -- injects into [:postgres, :custom_statements]
      add_legacy_key.ex                     -- adds the `legacy_id` attribute/calculation
  lib/ash_strangler/verifiers/
      verify_complete_mapping.ex
      verify_writable_mappings_reversible.ex
      verify_phase_transition.ex
      verify_identities_backed.ex
      verify_no_upserts.ex
  lib/ash_strangler/listener.ex             -- Postgrex.Notifications -> Ash.Notifier
  lib/ash_strangler/reconciler.ex           -- checksum/count drift detection
  lib/ash_strangler/backfill.ex             -- batched, resumable
  lib/mix/tasks/ash_strangler.check.ex      -- pre-flight assertions
  lib/mix/tasks/ash_strangler.status.ex     -- is the legacy write path dead yet?
  usage-rules.md
```

Two Spark extensions, not one: `AshStrangler.Resource` (the mapping) and `AshStrangler.Domain` (the listener
registration and the reconciliation schedule). Splitting them means a resource file never mentions runtime concerns.

## 5. The DSL

### 5.1 The whole thing, for one resource

```elixir
defmodule MyApp.Accounts.User do
  use Ash.Resource,
    domain: MyApp.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  attributes do
    # NOT `uuid_primary_key`, and NOT `integer_primary_key` — see §5.4. The id is
    # derived from the legacy key, so it cannot be generated client-side; and
    # `integer_primary_key` sets `generated? true, writable? false`, which is
    # wrong when you do not own the sequence.
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false

    attribute :email,       :ci_string, allow_nil?: false, public?: true
    attribute :full_name,   :string,    public?: true
    attribute :state_code,  :integer,   allow_nil?: false, default: 0
    attribute :archived_at, :utc_datetime_usec
    attribute :hashed_password, :string, sensitive?: true
  end

  postgres do
    repo MyApp.Repo
    table "users"
    schema "strangler"          # the compatibility schema, owned by this extension
    migrate? true               # Ash owns the VIEW; it does not own legacy.users
  end

  strangler do
    # The one control knob. Everything below is derived; this decides which
    # artifacts are derived from it.
    phase :read_from_legacy

    source "legacy.users" do
      # How the modern uuid is computed from the legacy integer key. Deterministic
      # so that SQL and Elixir agree without a lookup table.
      key :id, from: "id", strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

      # Plain column mappings. Bidirectional by construction.
      map :email,       "email",      cast: :citext
      map :archived_at, "deleted_at", cast: :timestamptz

      # Computed forward, explicit backward.
      map :state_code do
        from "CASE state WHEN 'active' THEN 0 ELSE 1 END"
        to   "CASE $NEW.state_code WHEN 0 THEN 'active' ELSE 'suspended' END", into: "state"
      end

      # Computed forward, no backward. `because` is required, and it lands in the
      # generated SQL as a comment and in the docs as a table.
      map :full_name do
        from "coalesce(first_name,'') || ' ' || coalesce(last_name,'')"
        writable? false
        because "Not decomposable: 'de la Cruz' splits wrong, and there is no rule that fixes it."
      end

      # Two legacy columns, one modern attribute. Forward only.
      map :hashed_password do
        from "'$legacy-sha1$' || salt || '$' || crypted_password"
        writable? false
        because "Password changes must not be written back into a SHA1 scheme. Cut over first."
      end

      # Columns with no legacy source at all.
      constant :organization_id, "'00000000-0000-0000-0000-0000000000fe'::uuid"

      # Attributes that exist on the resource and are deliberately not mapped.
      # Without this, compilation fails — see §6.2.
      unmapped [:created_by_id, :modified_by_id, :version_number], as: :null,
        because: "Provenance for pre-migration rows does not exist and cannot be manufactured."

      # The legacy uniqueness that actually exists, so AshPostgres can map
      # constraint violations back to the right Ash identity (§10.3).
      index "index_users_on_login", unique: true, columns: ["login"]
    end
  end
end
```

### 5.2 What that generates, per phase

`phase :read_from_legacy` derives exactly two statements:

```sql
-- statement :strangler_view_up
CREATE OR REPLACE VIEW strangler.users AS
SELECT
  uuid_generate_v5('6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71'::uuid,
                   'legacy.users:' || u.id::text)          AS id,
  u.id                                                     AS __legacy_id,
  u.email::citext                                          AS email,
  coalesce(u.first_name,'') || ' ' || coalesce(u.last_name,'') AS full_name,
  CASE u.state WHEN 'active' THEN 0 ELSE 1 END             AS state_code,
  u.deleted_at::timestamptz                                AS archived_at,
  '$legacy-sha1$' || u.salt || '$' || u.crypted_password   AS hashed_password,
  '00000000-0000-0000-0000-0000000000fe'::uuid             AS organization_id,
  NULL::uuid AS created_by_id, NULL::uuid AS modified_by_id, NULL::bigint AS version_number
FROM legacy.users u;

-- statement :strangler_notify_up
CREATE FUNCTION strangler.notify_users() RETURNS trigger AS $$ ... $$ LANGUAGE plpgsql;
CREATE TRIGGER strangler_users_notify
  AFTER INSERT OR UPDATE OR DELETE ON legacy.users
  FOR EACH ROW EXECUTE FUNCTION strangler.notify_users();
```

Change `phase` to `:dual_write` and the next `mix ash.codegen` adds the three `INSTEAD OF` triggers and the write-path
usage counter. Change it to `:read_from_new` and the generator emits the reversal: a new physical table, a backfill
migration, and a view *named `legacy.users`* defined over it so the old application keeps working unchanged. Change it
to `:decommissioned` and everything is dropped.

**The phase is the whole design.** One word decides which of a dozen artifacts exist, and the transition is a diff a
reviewer can read.

### 5.3 Directionality is explicit, always

The one thing this DSL will not do is guess. Every mapping is in exactly one of three states:

| Form | Forward | Backward | Compile-time rule |
|---|---|---|---|
| `map :email, "email"` | derived | derived | always fine |
| `map … from …/to …` | declared | declared | fine |
| `map … from …` + `writable? false` + `because:` | declared | none | fine in `:read_from_legacy`; in `:dual_write` the attribute is rejected on write with a real error naming `because` |
| `map … from …` with no `to:` and no `writable? false` | declared | — | **compile error** |

The last row is the important one. A tool that silently drops a column on write during dual-write causes exactly the
kind of quiet data loss these migrations are supposed to prevent. Making it a compile error is the single highest-value
constraint in the design, and `because:` being *required* rather than optional is not documentation theatre — it is
what ends up in the runtime error message a developer sees at 3am.

### 5.4 The primary key problem, in the DSL

Legacy integer keys against modern uuids is the first thing every user hits. Three strategies, declared:

```elixir
key :id, from: "id", strategy: {:uuid_v5, namespace: "..."}   # derived; no legacy writes
key :id, from: "row_uuid"                                     # a real column, after the expand step
key :id, from: "id", strategy: {:map_table, "strangler.user_ids"}  # when you cannot alter legacy at all
```

`{:uuid_v5, …}` uses `uuid_generate_v5` from `uuid-ossp`. It is `IMMUTABLE`, so `CREATE INDEX ON legacy.users
(uuid_generate_v5(ns, 'legacy.users:' || id::text))` works and lookups by modern id stay index-backed — the extension
emits that index automatically, because forgetting it turns every `Ash.get` into a sequential scan.

The reverse direction (uuid → integer) is *not* computable, which is why the view exposes `__legacy_id` and the
extension adds a `legacy_id` attribute to the resource. Every `INSTEAD OF UPDATE`/`DELETE` trigger keys off it rather
than off the uuid, so no trigger ever has to invert the hash.

### 5.5 Runtime configuration lives on the domain

```elixir
defmodule MyApp.Accounts do
  use Ash.Domain, extensions: [AshStrangler.Domain]

  strangler do
    repo MyApp.Repo
    pub_sub MyApp.PubSub

    listen? true              # start the Postgrex.Notifications listener
    channel "ash_strangler"   # one channel, resource in the payload

    reconcile do
      every :hourly
      on_drift :log           # :log | :raise | {:notify, MyApp.Alerts}
    end
  end
end
```

## 6. Architecture

### 6.1 Where it hooks into AshPostgres

Via `custom_statements`, and only via `custom_statements`. Verified against the vendored source of
`ash_postgres 2.11.0` / `spark 2.7.2` in this repository's `deps/`.

```elixir
# deps/ash_postgres/lib/statement.ex
%AshPostgres.Statement{name: atom, up: String.t(), down: String.t(), code?: boolean, global?: boolean}
# name / up / down are all `required: true`.
```

**Injection is mechanically feasible and unguarded.** `Spark.Dsl.Transformer.add_entity/4`
(`deps/spark/lib/spark/dsl/transformer.ex:275`) does a `Map.update` on a DSL state keyed by *section path only* — the
owning extension is discarded when the config map is built (`deps/spark/lib/spark/dsl/extension.ex:654`). There is no
ownership check and no `patchable?` gate on the transformer route. Build the entity properly rather than hand-rolling
the struct, because `build_entity/4` runs the target extension's own schema validation:

```elixir
{:ok, statement} =
  Spark.Dsl.Transformer.build_entity(
    AshPostgres.DataLayer,               # any extension module; it just walks its sections()
    [:postgres, :custom_statements],
    :statement,
    name: :strangler_users_view, up: up_sql, down: down_sql
  )

Spark.Dsl.Transformer.add_entity(dsl, [:postgres, :custom_statements], statement)
```

Three verified consequences worth designing around:

1. **`Spark.Dsl.Verifiers.VerifyEntityUniqueness`** is auto-prepended to every extension and *will* check injected
   statement names against hand-written ones. Prefix every generated name (`:strangler_*`) or a user's own statement
   will collide at compile time. This is good behaviour, not a problem — but the prefix has to be deliberate.
2. **Custom statements emit no schema prefix.** `AddCustomStatement` / `RemoveCustomStatement` are
   `defstruct [:statement, :table, no_phase: true]` and are rendered as bare `execute("…")`. Every other generated
   operation carries `prefix:`; these do not. **All generated SQL must schema-qualify itself**, always, including in
   the `down`. Forgetting is a bug that only appears when someone's `search_path` differs.
3. **`Spark.Dsl.Patch.AddEntity` also works**, and it is the route to take if the package ever wants to expose new
   syntax *inside* `custom_statements`. `custom_statements` does not set `patchable?`, but the gate at
   `extension.ex:2085` passes when the patch entity's `target` matches an existing entity's target — and
   `AshPostgres.Statement` does. If it did not match, the patch would be **silently dropped** with a warning.

There is **no precedent** for a third-party extension injecting into a *data-layer* extension's section: grepping all
~40 `ash_*` packages in `deps/`, the only cross-extension writes are into `Ash.Resource.Dsl` sections
(`ash_authentication` → `[:actions]`/`[:attributes]`/`[:relationships]`, `ash_paper_trail` → `[:relationships]` and
`[:changes]`, `ash_events` → action wrapping). The mechanism is identical and ungated, but this package would be
first, and "unprecedented but unguarded" is a maintenance risk to state rather than a green light.

The payoff for choosing `custom_statements` is large: generated DDL flows through `mix ash.codegen` into normal
migration files a human reviews, applied by a normal `mix ash.migrate`. **No new migration runner, no new state table,
no new deployment step.** The riskiest DDL in the system goes through exactly the same review and rollout path as every
other schema change.

The cost is ordering, and it is verified absolute (`migration_generator.ex:1834`):

```elixir
defp after?(%Operation.AddCustomStatement{}, _), do: true
defp after?(_, %Operation.RemoveCustomStatement{}), do: true
```

Every `Remove` runs first, every `Add` runs last, both are `no_phase: true` so they are never folded into a
`create table` block, and a *changed* statement becomes Remove-old-then-Add-new. See §10.6.

### 6.2 Transformers

| Module | What it does | Ordering |
|---|---|---|
| `AddLegacyKey` | Adds the `legacy_id` attribute (typed from `key … from:`) and the derived-id `default`, unless declared | before AshPostgres |
| `DeriveStatements` | Builds view + trigger SQL from the mapping and the phase; injects `AshPostgres.Statement` entities | after everything that can add attributes; **must** run after `AshEnterprise.Platform.Transformers.AddSystemAttributes`-style extensions or it will not see their columns |
| `SetOrigin` | Wraps write actions in a change that issues `SET LOCAL ash_strangler.origin = 'ash'` | any |

`DeriveStatements`' ordering constraint is subtle and worth calling out: the view's `SELECT` list must cover **every**
attribute on the fully-transformed resource. If another extension adds attributes after this transformer runs, the view
silently lacks them and every read of that column returns an error or a null. The verifier below is the safety net,
because verifiers run after all transformers.

### 6.3 Verifiers

Verifiers, not transformers, because these are assertions and Spark runs them last.

- **`VerifyCompleteMapping`** — every attribute is mapped, constant, or explicitly `unmapped`. This is the one that
  catches §6.2's ordering hazard.
- **`VerifyWritableMappingsReversible`** — in `:dual_write` and later, every writable attribute has a backward path or
  is explicitly `writable? false` with a `because:`.
- **`VerifyPhaseTransition`** — reads the previous phase from the resource snapshot in `priv/resource_snapshots` and
  rejects skips (`:read_from_legacy` → `:read_from_new` directly) and reversals that would drop data.
- **`VerifyIdentitiesBacked`** — an `identity` on a view is not enforced by anything, and worse, AshPostgres's
  migration generator would try to emit `CREATE UNIQUE INDEX` on it, which is invalid on a non-materialized view. Each
  identity must either name a legacy `index …, unique: true` in the DSL (from which the extension derives both
  `identity_index_names` and `skip_unique_indexes`), or be marked `enforced? false`. Silently unenforced uniqueness on
  a user table is a security defect, not an inconvenience.
- **`VerifyNoUpserts`** — no action on the resource uses `upsert?: true` while the resource is view-backed. See §10.2.
  This verifier is the difference between a compile error and a production 500.

The extension also has to set two AshPostgres options on the user's behalf, which is why they are worth naming here
rather than leaving to documentation: `skip_unique_indexes` for every identity backed by a legacy index (so the
generator does not emit an invalid `CREATE UNIQUE INDEX` against a view), and `require_primary_key? false` on the
resource when the source has no usable key. The latter is what `gen.resources --include-views` already does for
view-backed resources, so following its lead keeps the two mechanisms consistent.

### 6.4 Runtime pieces

Four, all optional, all supervised under the application's own tree rather than the extension's.

**`AshStrangler.Listener`** — the *bridge*, sitting on top of `ecto_watch` rather than replacing it (§2.1). On a
change event it decodes `{resource, legacy_id, op}`, re-reads through Ash (so calculations, policies and tenancy
apply), synthesizes an `Ash.Notifier.Notification`, and dispatches it. Payload carries the key only: `pg_notify` has a
hard payload ceiling, and re-reading through Ash is what makes the notification indistinguishable from an
Ash-originated one.

`Ash.Notifier.notify/1` is public and dispatch is **synchronous in the calling process** — there is no Task or spawn
in `deps/ash/lib/ash/notifier/notifier.ex`. Two verified traps:

- **`notification.action` must be the action struct, not its name.** `notifier.ex:417` dereferences
  `notification.action.name` unconditionally; an atom crashes the dispatch. So the listener has to look the action up
  with `Ash.Resource.Info.action/2` before building the struct.
- **`changeset` is optional for `notify/1` but required by `Ash.Notifier.PubSub`** for `:_tenant`, `:_pkey` and
  `previous_values?`. There is no changeset for a legacy write. The bridge therefore has to synthesize a minimal
  changeset carrying at least the resource, action and tenant, or accept that PubSub topic templates using `:_pkey`
  will not resolve. **This is a real limitation of the bridge and it is not obvious from the outside.**

Also: `notify/1` called inside a transaction for that resource returns the notification *unsent*, back to the caller.
The listener is not in a transaction, so this is fine — but a synchronous audit trigger (§10.4) would be, and would
have to handle it.

**`AshStrangler.Reconciler`** compares the two shapes: row counts, then per-batch checksums over the mapped columns.
Same code path in production (an Oban job) and in tests (a plain function returning a diff). This is deliberate: the
drift check *is* the correctness oracle, so it must be the same code in both.

**`AshStrangler.Backfill`** runs batched updates with a persisted cursor, `lock_timeout`, and a configurable batch
size and sleep. Nothing clever; the value is that it is resumable and that it reports progress, which is what makes a
40-million-row backfill a task someone will actually start.

**`mix ash_strangler.check`** is the pre-flight: for a given resource, run every assertion the Ash definition makes as
a plain SQL query against the legacy tables, and report violations. `allow_nil?: false` becomes
`SELECT count(*) WHERE col IS NULL`; `identity` becomes a `GROUP BY … HAVING count(*) > 1`; a type cast becomes a
`WHERE col IS NOT NULL AND col::target IS NULL` probe. **This is the first thing to build and probably the most
useful thing in the package**, because it answers "is my target model even satisfiable by this data" before a line of
DDL is generated, and it needs none of the rest of the machinery.

### 6.5 Three things AshPostgres already gets right

Worth recording, because they are the reasons this design is viable at all and each one would have been a blocker.

**Cross-schema joins work, same repo.** The join gate (`ash_postgres/lib/data_layer.ex:713`) compares only the data
layer module and the `:read` repo — schema is not part of the check — and each joined table is independently prefixed
by `AshSql.Join.join_prefix/3`. So a resource with `schema "legacy"` joins to a resource in `public` in a single query.
Without this, a legacy-backed resource could not have relationships to Ash-native ones, and the whole incremental story
collapses.

**`migrate? false` is purely a migration-generator flag.** Its only consumer is
`migration_generator.ex:42`. Queries, mutations, relationships, aggregates and policies behave identically. Snapshots
are still generated for unmanaged resources, so a *managed* resource can generate a correct foreign key pointing at an
unmanaged legacy table. That is precisely what the expand phase needs.

**The migration generator handles schemas properly** — it carries `schema` through snapshots, emits
`create table(…, prefix: "legacy")`, and prepends `CREATE SCHEMA IF NOT EXISTS` when
`repo.create_schemas_in_migrations?()`. Only `custom_statements` are unprefixed (§6.1), which is a bounded problem
because the extension controls every byte of that SQL.

One caveat that does not affect this repository but must be in the package docs: **`schema` combined with
`multitenancy strategy: :context` is not a supported combination.** `AshSql.repo_opts/5` gives the tenant precedence
and ignores `schema`; `AshSql.Join.join_prefix/3` gives `schema` precedence over the tenant. The behaviour therefore
depends on whether the resource is the query root or a join target. This repository uses attribute multitenancy, so it
is safe here — but a strangler user on schema-based multitenancy would hit it, and the verifier should reject the
combination outright rather than let them find it in production.

### 6.6 Suppressing double notifications

When Ash writes through the view, the `AFTER` trigger on the base table fires too, so a consumer sees the change
twice. The extension sets a transaction-local GUC on Ash-originated writes and the notify trigger checks it:

```sql
IF coalesce(current_setting('ash_strangler.origin', true), '') = 'ash' THEN RETURN NULL; END IF;
```

`SET LOCAL` is transaction-scoped, so it is safe with connection pooling — a pooled connection cannot leak it to the
next checkout. **But `SET LOCAL` outside a transaction block does nothing and emits a warning**, and AshPostgres
repos can be configured with `prefer_transaction? false` (this repository's own repo is). So the extension has to
force a transaction on write actions for the suppression to work at all, which costs a round trip on every single
write. The alternative — accept the duplicate and deduplicate in the listener by comparing against recent Ash-issued
notifications — is racy.

Neither option is good. The plan is to default to **not suppressing** (duplicates are visible and harmless to a
LiveView that re-reads) and make suppression opt-in with the transaction cost documented. Recording this here because
the source material in `docs/AshStrangler.md` presents GUC suppression as a clean optimization, and it is not.

## 7. The phases

| | `:read_from_legacy` | `:dual_write` | `:read_from_new` | `:decommissioned` |
|---|---|---|---|---|
| Source of truth | legacy tables | legacy tables | new tables | new tables |
| Compat view | over legacy, named for the modern shape | same | over new, named for the **legacy** shape | none |
| `INSTEAD OF` triggers | none | on the modern view | on the legacy-named view | none |
| Notify triggers | on legacy tables | on legacy tables | on new tables | none, Ash notifiers take over |
| Ash writes | rejected at compile time (`Verifier`) | through the view | direct to the table | direct |
| Legacy app writes | direct | direct | through the compat view | must be gone |
| Rollback | drop the view | drop the triggers | reverse the view definitions | none — this is the one-way door |

Two things are worth noticing about this table.

**The view flips direction, and its name flips with it.** In the first two phases the view is named for the modern
shape and reads from legacy tables. In `:read_from_new` a real table exists, and the *legacy* name becomes the view.
The legacy application's SQL does not change — it still says `SELECT * FROM users` — but `users` is now a view over
the new schema. That symmetry is what makes the cutover a migration rather than a coordinated deploy, and it is the
single most valuable thing the tool provides.

**Backfill is not a phase.** It is an operation that runs during `:dual_write` and must complete before
`:read_from_new`. Modelling it as a phase would imply it is instantaneous; it is the part that takes weeks.

### 7.1 Knowing when it is safe to contract

The `contract` step is where migrations stall, because nobody can prove the legacy write path is dead. The extension
generates a usage counter inside every compatibility trigger:

```sql
INSERT INTO ash_strangler_usage (resource, path, day, count)
VALUES ('MyApp.Accounts.User', 'legacy_write', current_date, 1)
ON CONFLICT (resource, path, day) DO UPDATE SET count = ash_strangler_usage.count + 1;
```

`mix ash_strangler.status` reads it and prints, per resource, the last day each path was used. That is the evidence
required to move a phase, and it is cheap — one upsert on a tiny table per legacy write. Making the decision
*evidential* rather than *argued* is the difference between a migration that finishes and one that does not.

## 8. Testing strategy

This is data-migration tooling. A bug here is silent, discovered later, and expensive. The test suite is the product.

**8.1 Real Postgres, no mocks, a version matrix.** Every test runs against a live server. CI matrices over PG 14–17
because the SQL generated depends on version-specific behaviour and the whole point is to be trustworthy.

**8.2 Golden SQL files.** DSL in, SQL out, checked in as fixtures. Changing the generator produces a diff a human
reads. This catches nothing about correctness and everything about *unintended* change, which is the more common
failure in a code generator.

**8.3 Round-trip property tests — the core of the suite.** With `StreamData`: generate an arbitrary legacy row,
insert it with plain SQL, read it through the view as an Ash record, write it back through the `INSTEAD OF` triggers,
read it again, assert equality on every mapped attribute. Shrink to a minimal failing row. This is the test that
finds cast bugs, NULL handling bugs, timezone bugs, and unicode bugs, and it finds them without anyone having thought
of the case.

**8.4 Differential dual-write tests.** For each logical operation, do it twice against two identical databases — once
through the legacy path (raw SQL) and once through the Ash action — then assert the two databases are byte-identical
under `pg_dump --data-only`. Legacy and modern write paths agreeing is the actual invariant of the dual-write phase,
and this asserts it directly rather than by proxy.

**8.5 The reconciler is the oracle.** The same `AshStrangler.Reconciler.diff/1` used by the scheduled job is the
assertion in tests. If the reconciler is wrong, tests pass and production drifts — so the reconciler itself needs
mutation tests: deliberately corrupt one row, assert the diff finds it. A drift detector nobody has proven can detect
drift is worse than none, because it manufactures confidence.

**8.6 A phase-transition conformance suite**, in the style of this repository's
`test/ash_enterprise/security/conformance_test.exs`: an explicit truth table over (mapping kind × phase × operation)
with the expected outcome for each cell, including the cells that must *fail*. Written as an executable copy of §7
rather than as a test of the implementation, so it is the first thing to read when behaviour surprises you.

**8.7 Migration idempotency.** `up`, `down`, `up`, then `pg_dump --schema-only` and diff. Any generated migration that
is not exactly reversible is a bug, and this is the only phase-transition guarantee that matters at 3am.

**8.8 Failure injection.** Kill the listener mid-stream and assert the *data* path is unaffected and the notification
loss is visible in a metric rather than silent. Saturate the notify queue and assert the same. The package must be
honest that notifications are best-effort, and the test suite is where that honesty is enforced.

**8.9 Adversarial fixtures.** The test legacy schema carries case-colliding emails, NULLs in `NOT NULL` targets,
orphaned FKs, timestamps in three zones, and values that do not cast. `mix ash_strangler.check` must find all of them.
See the reference-app plan §3.

**8.10 A scale test, run nightly, not in PR CI.** 10 million rows, measure backfill throughput and lock duration.
Marked clearly as the *only* evidence about scale, because everything else in the suite is small.

## 9. Repository and release

| | |
|---|---|
| Name | `ash_strangler` — searchable, and it names the pattern rather than the mechanism. `ash_legacy` was considered and rejected as too broad; `ash_expand_contract` as too obscure. |
| Repo | `github.com/lukegalea/ash_strangler`, standalone. Not vendored here. |
| License | MIT, matching `ash`, `ash_postgres` and the rest of the ecosystem. |
| Version | `0.1.0`, README stating **alpha** plainly. By this repository's own tier rules ([thesis 6](../manifesto/06-reversibility.md)) it is **tier 3** until it has real deployments — isolated behind a seam, removable by deletion. |
| Hex | `mix hex.publish`, `ex_doc`, Spark DSL docs generated into `documentation/dsls/` via `mix spark.cheat_sheets`. |
| Installer | `mix igniter.install ash_strangler` adding the deps entry, the formatter `import_deps`, and the supervision-tree child. Standard for the ecosystem and the thing that makes a package feel finished. |
| CI | GitHub Actions: Elixir/OTP matrix × PG 14/15/16/17; `mix format --check-formatted`; `mix credo --strict` with `ash_credo`; `mix test`; `mix hex.audit`; Dialyzer **non-blocking**, matching this repository's stated policy for Spark-generated code. |

### `usage-rules.md`

The package ships one at its root. This repository's `mix.exs` already gathers `~r/^ash_/` usage rules into
`AGENTS.md` and into a `.claude/skills/ash-framework` skill, so adding the dependency picks it up with no further
configuration. That is worth optimizing for: an AI agent editing a strangler mapping without knowing the phase rules
will produce something that compiles and loses data.

Contents, in priority order:

1. **The phase model**, as the table in §7. An agent that does not know what phase a resource is in cannot reason about
   whether a change is safe.
2. **Never hand-edit a generated migration statement.** Edit the mapping and regenerate. A hand-edited statement is
   invisible to the diffing generator and will be reverted on the next codegen.
3. **`writable? false` requires `because:`, and the text is user-facing.** It appears in the runtime error.
4. **Never add `upsert?: true` to a view-backed resource** (§10.2).
5. **Adding an attribute to a strangler-backed resource is a schema change**, because the view's `SELECT` list must
   grow. Regenerate.
6. **`mix ash_strangler.check` before every phase change**, no exceptions.

## 10. What is genuinely hard

Ten things. Some are solvable with care; three are not solved and would ship as documented limitations.

> §10.1–10.6 were **executed against PostgreSQL 17.10** (this repository's `devenv` server) rather than inferred from
> documentation. Where a result contradicts what the source documents in `docs/` assume, the executed result wins. Two
> findings are worse than the documents assume (§10.1, §10.2), one is materially better (§10.6), and one is a hazard
> nobody named (§10.3).

### 10.1 `RETURNING` through `INSTEAD OF` triggers — confirmed, and it fails silently

Ecto relies on `RETURNING` for generated values, and Ash relies on Ecto. On a view with an `INSTEAD OF INSERT`
trigger, `RETURNING` reports **the row the trigger function returned**, not the row that was stored. The obvious
trigger body — insert, then `RETURN NEW` — returns nulls for every column the client did not supply:

```
INSERT INTO strangler.users (login, email, full_name) VALUES ('alice',…) RETURNING id, legacy_id, created_at;
 id | legacy_id | created_at
----+-----------+------------
    |           |                 <- and yet the row IS stored, with id 5ecf8b7b-…, legacy_id 1, created_at now()
```

Ash would hold a record with a **null primary key** and no error raised. Every generated trigger must therefore
re-read and return the stored row:

```sql
INSERT INTO legacy.users (…) VALUES (…) RETURNING * INTO rec;
SELECT * INTO NEW FROM strangler.users WHERE legacy_id = rec.id;
RETURN NEW;
```

With that, `RETURNING` reports the real `id`, `legacy_id` and `created_at`. Mechanical to get right, catastrophic to
get wrong, invisible when wrong — which is precisely the case for a generator owning it. It is the first thing §8.3's
round-trip property test exercises.

### 10.2 Upserts — confirmed unavailable, in both failure modes

`ON CONFLICT` needs a real index to arbitrate and a view has none. Both forms fail, and they fail *differently*
depending on the view's shape:

| Attempt | Result on a single-table view | Result on a joined view |
|---|---|---|
| `ON CONFLICT (login) DO UPDATE` | `ERROR: there is no unique or exclusion constraint matching the ON CONFLICT specification` | `ERROR: cannot insert into view … Views that do not select from a single table or view are not automatically updatable` |
| `ON CONFLICT DO NOTHING` | **conflict not caught**; the base table's unique violation propagates as an error | same |

The second row is the dangerous one: `DO NOTHING` does not swallow the conflict, it lets the base-table violation
escape from inside the trigger. So **any Ash action using `upsert?: true` is unavailable on a view-backed resource**,
including `Ash.Changeset.for_create(…, upsert?: true)` and several `ash_authentication` strategies. `VerifyNoUpserts`
converts this from a production 500 into a compile error, which is the only good outcome available.

`MERGE` is a partial exception (§10.3) and is not a safe substitute.

The remaining open question is behavioural, not documentary: **how many Ash and `ash_authentication` paths silently
depend on upserts.** That determines whether the package can honestly claim to support authentication resources, and
it needs a spike against a real application rather than a real database.

### 10.3 Views are auto-updatable, and that is a hazard as much as a gift

This is the finding the source documents get wrong, in the optimistic direction *and* the pessimistic one.

A view that selects from a **single** base table is automatically updatable **even if it has computed columns**.
Verified: `information_schema.views` reports `is_updatable YES`, `is_trigger_updatable NO` for the example view, and:

- `UPDATE strangler.users SET email = …` — **succeeds with no `INSTEAD OF UPDATE` trigger at all.** Postgres routes it
  to the base table.
- `UPDATE strangler.users SET full_name = …` — `ERROR: cannot update column "full_name" of view "users" / View columns
  that are not columns of their base relation are not updatable.`
- `DELETE FROM strangler.users …` — succeeds, no trigger.
- `MERGE INTO strangler.users … WHEN MATCHED THEN UPDATE / WHEN NOT MATCHED THEN INSERT` — **succeeds**, routed by the
  auto-update rule, bypassing whatever `INSTEAD OF` logic exists for the operations that do have triggers.

The gift: for a single-table legacy source, `INSTEAD OF UPDATE`/`DELETE` triggers may be unnecessary, and Postgres
itself enforces the "computed columns are read-only" rule with a clear error. Less generated SQL is strictly better.

The hazard, and it is the more important half: **writes reach the base table through a path the extension did not
generate and cannot see.** The mapping's intent — cast this, transform that, log the other — is bypassed. `MERGE` is
the worst case because it is a single statement that can insert *and* update, and it took the auto-update path even
though an `INSTEAD OF INSERT` trigger existed.

The resolution is to always generate the full set of `INSTEAD OF INSERT/UPDATE/DELETE` triggers in `:dual_write`, even
where auto-updatability would have worked, precisely so that no write can take an ungoverned path. Adding an
`INSTEAD OF UPDATE` trigger both routes the write *and* unlocks computed-column updates — verified: with the trigger
present, `UPDATE … SET full_name = …` no longer errors, because the trigger receives it in `NEW` and decides.

Which produces the last hazard, and the sharpest one: **a trigger that returns `NEW` without writing anything reports
`UPDATE 1`.** Verified directly — a no-op `INSTEAD OF UPDATE` trigger that only raises a notice returned a successful
row count. Silent data loss with a success response is the exact failure mode this whole exercise exists to prevent,
and it is why §5.3 makes an unmapped writable attribute a *compile* error rather than a runtime warning.

### 10.4 Constraint errors carry the base table's name

Verified: a duplicate through the view raises

```
ERROR:  duplicate key value violates unique constraint "index_users_on_login"
CONTEXT: SQL statement "INSERT INTO legacy.users …"  PL/pgSQL function strangler.users_ins() line 3
```

— the *base table's* index name, not the identity name Ash expects, so Ash's constraint-to-error mapping misses and
the user sees a 500 instead of a validation error. AshPostgres has the hatch (`identity_index_names` /
`unique_index_names`, matched per `default_constraint_match_type/2`) but it must be populated, which is why the DSL
requires legacy indexes to be declared and derives the mapping from that.

**A partial solution.** The verifier catches only the indexes the user remembered to declare. Introspecting
`pg_indexes` at compile time would close the gap, but compile-time database access is a hard no for a library. A
`mix ash_strangler.check` sub-check that compares declared indexes against `pg_indexes` at *runtime* is the honest
compromise.

Related and also verified: **row-level `BEFORE`/`AFTER` triggers cannot exist on a view** (`ERROR: "users" is a view /
Views cannot have row-level BEFORE or AFTER triggers`). Statement-level `AFTER` triggers on a view *are* allowed. So
the notify trigger must live on the base table, which is what the design already assumed — but it also means there is
no per-row hook on the view itself for auditing what came through it. The usage counter (§7.1) has to live inside the
`INSTEAD OF` function.

### 10.4 Notifications are best-effort, and an audit log is not

`pg_notify` is at-most-once with a bounded queue and a payload ceiling. A listener that is down misses events
permanently, and a full queue fails the *transaction that issued the NOTIFY*. This is entirely fine for LiveView
reactivity and cache invalidation, and entirely unacceptable for a compliance audit trail.

The package must say so in the README rather than letting users discover it. Where a complete record of legacy writes
is required, the mechanism has to be a synchronous trigger inserting into an events table inside the legacy
transaction — which couples the legacy app's availability to the audit table's health. That is a real tradeoff with no
right answer, and the package should support both and refuse to pick.

### 10.5 Policy filters over views

Ash policies produce `WHERE` clauses. Against a single-table view Postgres inlines the predicate and the base table's
indexes are used. Against a view with joins, `DISTINCT`, or aggregates, pushdown is not guaranteed, and a filter on a
*computed* column — which `owning_business_unit_id` is, in the reference-app design — cannot use an index at all
unless one was built on the expression.

The extension can emit expression indexes for columns it knows are filtered on, but it does not know which those are.
The realistic answer is that **complex views are for the read phase only**, and the expand step (real columns, real
indexes) is a prerequisite for any resource under meaningful load. That should be a documented rule, not a discovery.

### 10.6 Migration ordering

`custom_statements` are diffed by name and ash_postgres's own documentation is explicit that it cannot determine
ordering, that all `down`s run before all `up`s, and that changing a statement regenerates it as down-then-up. For a
single view that is fine. For a view another view depends on, the `DROP` fails or needs `CASCADE`; for a trigger whose
function is in a different statement, the ordering is wrong.

Mitigations: emit one statement per resource containing all of its DDL (fewer, larger statements order themselves
internally), and use `CREATE OR REPLACE` where Postgres allows it so the down-then-up cycle is avoided entirely.
`CREATE OR REPLACE VIEW` cannot change a column's type or drop a column, so this only goes so far. **Unresolved for
cross-resource dependencies**, and the fallback is that the package generates the statements and a human orders the
migration — which is a defensible position for DDL this consequential, but it is not the "fully derived" story.

### 10.7 Phase transitions are stateful, and Spark verifiers are read-only

`VerifyPhaseTransition` needs the previous phase. Spark verifiers are strictly read-only by API surface —
`Spark.Dsl.Verifier` delegates only `get_persisted`, `get_option`, `fetch_option` and `get_entities`
(`deps/spark/lib/spark/dsl/verifier.ex:65`) — and they run at compile time with no portable filesystem or database
contract. So the previous phase has to come from somewhere else.

Piggybacking on `priv/resource_snapshots` is tempting because AshPostgres already writes it and it is already in
version control. But it is another package's private artifact format, read from a compile-time verifier, and it will
break. The alternative is the extension keeping its own snapshot, which is cleaner and is one more thing to keep in
sync. A third option is to give up on compile-time checking entirely and make phase transition a mix task that
inspects the database (`mix ash_strangler.phase MyApp.User --to dual_write`), which is where this probably lands —
compile-time verification of a *stateful* transition was the wrong instinct. **Undecided.**

### 10.8 Passwords, and everything else the mapping cannot reach

Legacy password hashes cannot be converted. Encrypted columns cannot be re-keyed by a view. Serialized Ruby YAML
columns cannot be usefully projected. Every real migration has at least one of these, and none of them are schema
mapping problems.

The correct posture is for the package to be *loudly incomplete* about it: `writable? false` with a mandatory
`because:` is the mechanism, and the docs should carry a worked example of the password case specifically, ending in
"and now you write a custom hash provider by hand." A tool that leaves you holding the hard part is still valuable.
A tool that implies there is no hard part is worse than nothing.

### 10.9 It might not be worth building

Stated last because it is the honest conclusion of §2 and must survive the enthusiasm of the preceding nine sections.
The mechanism — views and `INSTEAD OF` triggers — is well understood and hand-writable. What the package adds is
derivation, verification, and phase management. If the verification (§6.3) and the pre-flight check (§6.4) are the
valuable parts, and the SQL generation is the risky part, then **the honest minimum viable package is
`mix ash_strangler.check` plus the verifiers, with the SQL left to the user.** That is a much smaller thing and it
delivers most of the value on the first day.

The decision gate in §11 is designed to find out.

## 11. Sequencing, and the spikes that come first

Two of the three original spikes are already answered from source reading; one remains, and it is the one that
constrains the claim.

1. ~~**Can a third-party Spark transformer add entities to `[:postgres, :custom_statements]`?**~~ **Answered: yes.**
   `add_entity/4` is ungated and keyed on section path only; `build_entity/4` validates against the target extension's
   schema; `VerifyEntityUniqueness` checks the names. Unprecedented in a data-layer section, but mechanically sound.
   §6.1.
2. **Does `RETURNING` behave as §10.1 describes?** Documented behaviour says the trigger's return value is what
   `RETURNING` reports. That was established from the Postgres documentation, not by execution. A twenty-line SQL
   script confirms or refutes it and is the cheapest high-value thing to run.
3. **Does `INSERT … ON CONFLICT` work against a view with `INSTEAD OF` triggers?** Expected: no. AshPostgres emits both
   an `ON CONFLICT` path (`data_layer.ex:2316`) and a PG17 `MERGE` path (`lib/merge.ex`), and both need a real conflict
   target that a view cannot provide. §10.2. The open question is *behavioural*, not documentary: how many Ash and
   `ash_authentication` code paths silently depend on upserts. That needs a spike against a real database, and it
   determines whether the package can honestly claim to support authentication resources at all.

Then, in order:

Then, in order:

| Step | Deliverable | Why this order |
|---|---|---|
| 1 | `mix ash_strangler.check` + the verifiers, no SQL generation | Standalone value, zero risk, answers §10.9 |
| 2 | View generation, `:read_from_legacy` only | The smallest useful generator |
| 3 | Round-trip property test harness | Before write generation, not after |
| 4 | `INSTEAD OF` triggers, `:dual_write` | The risky part, with the oracle already in place |
| 5 | Listener + notifications | Independent; genuinely useful on its own |
| 6 | Backfill + reconciler | |
| 7 | `:read_from_new` reversal, `:decommissioned` | The one-way door, built last |

**Step 1 is the decision gate.** If it is useful on its own and steps 2–4 look worse in the writing than they do in
this document, ship step 1 as the whole package and write a guide for hand-rolling the rest. That is a legitimate
outcome, and pre-committing to it is the main reason this plan exists in written form before any code.
