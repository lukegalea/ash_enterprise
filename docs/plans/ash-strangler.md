# Plan — AshStrangler

- **Status:** **DEFERRED.** Not started, not scheduled. Do not begin until the current phases are complete —
  Organization and tenancy (Phase 5), hierarchy security (Phase 6). Written now because the design questions are cheap
  to answer on paper and expensive to answer in code, and because [§10](#10-what-is-genuinely-hard) records findings
  that hold whether or not the package is ever built.
- **Date:** 2026-08-13
- **Scope:** a *standalone open-source package*, living outside this repository. There is nothing to add to `mix.exs`
  here.
- **Replaces the guidance in:** `docs/AshStrangler.md` and
  `docs/Strangler Fig Migrations for Postgres Schemas…md`, both raw research transcripts. They are useful for their
  citations and wrong in several specifics — see [§10](#10-what-is-genuinely-hard), where six of their assumptions are
  corrected against an executed test.
- **Companion:** [`ash-strangler-in-reference-app.md`](ash-strangler-in-reference-app.md) — how this repository would
  demonstrate it, and the platform conflicts that surfaces.

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

> **Revisited 2026-08-14**, past this table's README-level read, into `pgroll`'s actual Go source (asked directly:
> "can we leverage it to accelerate development?"). The verdict does not change — its migration is `add_column` /
> `rename_column` / `alter_column` on a schema it owns, versioned by which Postgres schema a session's `search_path`
> points at; there is still no way to hand it "this legacy relation, mapped onto this Ash resource," and its own
> `Start` → dual-write → `Complete`-or-`Rollback` lifecycle is validated confirmation that this plan's phase model has
> the right shape, not something to import. But its `Start`/`Complete` split for `OpAlterColumn`
> (`pkg/migrations/op_alter_column.go`) is a clean worked example of exactly this plan's expand/dual-write/contract
> idea at column scope, and its backfill package (`pkg/backfill/`) contains one concrete, non-obvious improvement over
> this plan's own §6.4 sketch, recorded there: a dedicated `_needs_backfill` flag column instead of `IS NULL`, and
> `FOR NO KEY UPDATE` in the batch query. Go and Elixir, so it is a reference to read, not a dependency to add.

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
  > **Revisited when step 5 was built, and deviated from.** `ecto_watch` rebroadcasts to `Phoenix.PubSub`, which this
  > package does not otherwise depend on — adopting it would add `phoenix_pubsub` to a schema-mapping library's
  > dependency tree (verified absent from `mix.lock`). And it cannot do the part that matters: re-reading through Ash
  > and synthesizing an `Ash.Notifier.Notification`. Since the package already generates triggers, generating one more
  > notify trigger is marginal, and the listener is ~150 lines against `Postgrex.Notifications` with the builtin `JSON`
  > module — **zero new dependencies**. The README tells anyone already running `ecto_watch` to prefer it for the
  > transport and hand the key to `AshStrangler.Listener.notify/2`, which keeps §2.1's finding useful without paying
  > for it.
- **Not justified:** the `legacy_api` HTTP layer from `docs/AshStrangler.md`. Different package, and
  `reverse_proxy_plug` plus hand-written controllers already covers it.

The uncomfortable version of the verdict: **the two most valuable pieces (§6.3 verifiers, §6.4 pre-flight check) are
also the two that need no SQL generation at all.** §11 is built around finding out whether the rest earns its risk.

## 3. Scope

**In scope.**

1. A declarative mapping from a legacy relation (or a small join of them) to an Ash resource's attributes.
2. Derivation of the compatibility DDL — view, expression indexes, `INSTEAD OF` triggers *where the mapping requires
   them*, `AFTER` notify triggers — emitted through AshPostgres's existing `custom_statements` so it lands in ordinary
   generated migrations. "Where the mapping requires them" is load-bearing, not a hedge: §10.2.
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
      # constraint violations back to the right Ash identity (§10.4).
      index "index_users_on_login", unique: true, columns: ["login"]

      # How writes reach the base table. Derived by default from the mapping
      # shape; declaring it is an override with a real cost either way (§10.2).
      #   :auto     — rely on Postgres view auto-updatability.
      #               Keeps upserts, correct RETURNING, WITH CHECK OPTION.
      #               Loses the usage counter and lets MERGE bypass the mapping.
      #   :triggers — generate INSTEAD OF INSERT/UPDATE/DELETE.
      #               Governs every write. Destroys all three of the above.
      writes :auto
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

Plus the expression index that keeps `Ash.get` off a sequential scan — verified necessary and verified sufficient
(§10.1's companion measurement in the reference-app plan §4.1):

```sql
-- statement :strangler_users_key_index
CREATE INDEX IF NOT EXISTS strangler_users_key_idx ON legacy.users
  (uuid_generate_v5('6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71'::uuid, 'legacy.users:' || id::text));
```

Change `phase` to `:dual_write` and the next `mix ash.codegen` adds the write path — **but which write path is
derived, not fixed.** §10.2 is the reason: an `INSTEAD OF` trigger silently costs upserts, correct `RETURNING` and
`WITH CHECK OPTION`, so it is generated only where the mapping requires it.

| Mapping shape | Generated for `:dual_write` |
|---|---|
| one source table, only plain `map` entries, no `constant` | **nothing** — Postgres auto-updates the view |
| any writable computed mapping (`to:`) | `INSTEAD OF UPDATE` (and `INSERT` if it is set on create) |
| a `join`, i.e. more than one source table | all three; auto-updatability does not apply |
| `usage_counter? true` | all three, because the counter has nowhere else to live (§10.3) |

`writes: :auto | :triggers` in the `source` block overrides the derivation, with the trade documented on the option.
Where triggers *are* generated, each re-reads and returns the stored row rather than `NEW`, which is §10.1's reason:

```sql
-- statement :strangler_users_insert_up  (abridged)
CREATE OR REPLACE FUNCTION strangler.users_insert() RETURNS trigger AS $$
DECLARE rec legacy.users;
BEGIN
  INSERT INTO legacy.users (email, state, deleted_at)
  VALUES (NEW.email, CASE NEW.state_code WHEN 0 THEN 'active' ELSE 'suspended' END, NEW.archived_at)
  RETURNING * INTO rec;
  PERFORM strangler.count_use('MyApp.Accounts.User', 'ash_write');
  -- MUST re-read: RETURNING on the view reports what this function returns, not what was stored.
  SELECT * INTO NEW FROM strangler.users WHERE __legacy_id = rec.id;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
```

Change it to `:read_from_new` and the generator emits the reversal: a new physical table, a backfill migration, and a
view *named `legacy.users`* defined over it so the old application keeps working unchanged. Change it to
`:decommissioned` and everything is dropped.

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

> ⛔ **This section's conclusion is WRONG, and it was the load-bearing architectural decision of the whole plan.**
> Corrected 2026-08-14 while building step 7, by generating an actual migration and reading it. Everything below about
> the *mechanism* is accurate — a third-party transformer really can inject into `[:postgres, :custom_statements]`, it
> really is ungated, and the entity really does validate. What is wrong is the assumption that doing so **produces a
> migration that runs**.
>
> A strangler resource's `table` names a **view**. Both possible settings of `migrate?` fail, in opposite directions:
>
> | `migrate?` | Result |
> |---|---|
> | `true` (default) | The generator emits `create table(:users, prefix: "strangler")` for the view's own name, *and* the view DDL. `CREATE OR REPLACE VIEW` against an existing table fails, so the migration cannot run at all. |
> | `false` | `MigrationGenerator` splits resources into managed and unmanaged (`migration_generator.ex:41`), and **only managed resources produce snapshots** — which is where `custom_statements` are read from (`:1071`). The view, index and triggers are silently dropped. |
>
> Both were verified by running `mix ash.codegen` and reading the output, not inferred. There is no setting in
> between, so **`custom_statements` cannot carry DDL for a view-backed resource.**
>
> The resolution: the resource declares `migrate? false` (enforced by `AshStrangler.Verifiers.VerifyNotMigrated`, with
> that explanation in the error), and the DDL is emitted by a dedicated `mix ash_strangler.gen.migration`. This is the
> position AshPostgres itself already takes — `mix ash_postgres.gen.resources --include-views` writes `migrate? false`
> beside a comment saying migrations for views are handled manually. The package automates the manual part.
>
> **What was lost:** the "flows through ordinary codegen, no new step" property this section argued was the whole
> payoff. **What was gained, unexpectedly:** the `down`s can now be emitted in reverse order, because a single
> generated migration controls its own sequence. The `custom_statements` path could not do that — it runs every
> `Remove` before every `Add`, in list order — which is why §10.8's statements had to be individually
> order-independent. The replacement is strictly simpler on that axis.
>
> **The general lesson, and it is the same one as §10.1, §10.8 and §10.12:** the mechanism was verified in isolation
> and the *outcome* was not. Reading `add_entity/4` proved a statement could be injected. Only generating a migration
> proved what the migration then contained.

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
`create table` block, and a *changed* statement becomes Remove-old-then-Add-new. See §10.8.

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
- **`VerifyNoUpserts`** — conditional, and the condition is the point. Upserts work fine on an auto-updatable view;
  they are destroyed by an `INSTEAD OF` trigger (§10.2). So this rejects `upsert?: true` only where the mapping forced
  a trigger, and the error names *which* mapping did it — turning an inexplicable limitation into one the user can act
  on by removing that mapping or deferring that action past cutover.

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
The listener is not in a transaction, so this is fine — but a synchronous audit trigger (§10.6) would be, and would
have to handle it.

**`AshStrangler.Reconciler`** compares the two shapes: row counts, then per-batch checksums over the mapped columns.
Same code path in production (an Oban job) and in tests (a plain function returning a diff). This is deliberate: the
drift check *is* the correctness oracle, so it must be the same code in both.

**`AshStrangler.Backfill`** runs batched updates with a persisted cursor and reports progress — the value is that it is
resumable, which is what makes a 40-million-row backfill a task someone will actually start. The mechanics are not
clever but they are specific, and getting any of them wrong turns a background task into an outage:

- **Keyset pagination**, `WHERE id > $last ORDER BY id LIMIT $batch`, never `OFFSET`. One committed transaction per
  batch. A single large `UPDATE` holds row locks for the whole run, pins the global xmin so `VACUUM` reclaims nothing
  cluster-wide, and cannot be resumed.
- **Idempotent predicate: a dedicated flag column, not `AND new_col IS NULL`.** Read directly from `pgroll`'s Go source
  (`pkg/backfill/`, `xataio/pgroll` @ github.com, 2026-08-14 — going past §2.3's README-level survey into the actual
  implementation): it adds `_pgroll_needs_backfill boolean DEFAULT true`, sets it `false` inside the sync trigger once
  a row is populated, and batches `WHERE _pgroll_needs_backfill = true`. `IS NULL` is the wrong predicate whenever the
  target column's *correct* value can legitimately be null — which `unmapped …, as: :null` guarantees will happen here
  — because then a fully-backfilled row is indistinguishable from one still waiting, and the batch loop never
  terminates. Its batch query is also worth copying directly: a `WITH batch AS (SELECT pk … LIMIT n FOR NO KEY UPDATE)
  UPDATE … FROM batch … RETURNING pk` — `FOR NO KEY UPDATE` rather than a bare `FOR UPDATE` so the batch lock doesn't
  needlessly block concurrent FK checks referencing these rows.
- **`lock_timeout` on every DDL statement, with a retry loop.** A DDL statement waiting for `ACCESS EXCLUSIVE` sits at
  the head of the lock queue and every subsequent `SELECT` queues behind it — one slow reader plus one waiting
  `ALTER TABLE` takes the table offline. `statement_timeout` is not a substitute: it also kills a DDL that has already
  acquired its lock and is doing legitimate work. Catch SQLSTATE `55P03`, back off, retry.
- **`CREATE INDEX CONCURRENTLY` cannot run in a transaction block** (`@disable_ddl_transaction true` in Ecto), it waits
  on *any* long-running transaction including concurrent index builds elsewhere for partial or expression indexes, and
  **on failure it leaves an invalid index behind that still costs write throughput and, if unique, still enforces
  uniqueness.** Every CIC must be followed by a `pg_index.indisvalid` check; the failure is otherwise silent.
- **`ADD COLUMN` rewrites the table for a volatile default.** Verified on 17.10 by comparing `pg_relation_filenode`:
  a constant default does not rewrite; `gen_random_uuid()` does, as does a stored generated column. So the expand step
  adds nullable columns and backfills, rather than adding a defaulted `uuid` column — which is the tempting shortcut
  for §5.4's key problem and would take `ACCESS EXCLUSIVE` for the duration of a full rewrite.
- **`SET NOT NULL` without a full-table scan** is the four-step `CHECK … NOT VALID` → `VALIDATE CONSTRAINT`
  (`SHARE UPDATE EXCLUSIVE`, concurrent DML fine) → `SET NOT NULL` (scan skipped, PG 12+) → `DROP CONSTRAINT`.
  `UNIQUE` cannot be `NOT VALID` at all — that path is `CREATE UNIQUE INDEX CONCURRENTLY` then
  `ADD CONSTRAINT … USING INDEX`.
- **Lower `fillfactor` before a heavy backfill** so updates can stay HOT, and index the new column *after* the
  backfill rather than before.

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

**And a fourth, which is why this design does not copy pgroll's versioned-schema model.** pgroll publishes one schema
per migration version and has clients opt in with `SET search_path`. That is elegant, and it is a poor fit here for a
reason that has nothing to do with Ash: **`search_path` was not a `GUC_REPORT` parameter before PostgreSQL 18**, so
pgbouncer cannot track it, so under transaction pooling a session-level `search_path` either leaks to unrelated
clients or silently vanishes. PG 18 marked it reportable (commit 28a1121f) and `track_extra_parameters = search_path`
makes the model viable — but this repository declares a floor of PG 14. AshPostgres emitting schema-qualified SQL
via `prefix` puts the schema in the statement text instead of in session state, which is pooler-proof by
construction. That is the right trade for a tool whose whole purpose is not to surprise anyone in production.

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
| `INSTEAD OF` triggers | none | **only if the mapping requires them** (§5.2) | on the legacy-named view, usually required | none |
| Upserts (`upsert?: true`) | n/a — writes rejected | available iff no trigger was generated (§10.2) | available | available |
| Notify triggers | on legacy tables | on legacy tables | on new tables | none, Ash notifiers take over |
| Ash writes | rejected at compile time (`Verifier`) | through the view | direct to the table | direct |
| Legacy app writes | direct | direct | through the compat view | must be gone |
| Rollback | drop the view | drop the triggers | reverse the view definitions | none — this is the one-way door |

Note the asymmetry in the trigger row. Going *out* of the legacy schema, the compatibility view often needs no triggers
at all, because a single-table projection is auto-updatable. Coming *back* — a view named `legacy.users` over an
Ash-owned table whose shape differs — almost always does, because that direction is where the interesting reshaping
lives. So the `:read_from_new` phase is where the §10.2 trade actually bites, and by then the legacy application is
the only thing writing through the view, so losing upserts on it matters much less. That is a convenient alignment
rather than a designed one, and it should be checked rather than assumed.

Two more things are worth noticing about this table.

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

**8.11 Five named regression tests, one per hazard §10 found by execution.** These are not general properties; they are
specific traps with specific assertions, and each would otherwise be discovered in production:

| Test | Asserts |
|---|---|
| `returning_is_not_null` | `Ash.create!` on a view-backed resource returns a record with a non-nil primary key and a populated `created_on`. Fails against the naive trigger (§10.1) |
| `upsert_survives_auto_mode` | `upsert?: true` **works** on a resource whose mapping needs no triggers, and is a compile error naming the offending mapping on one that does (§10.2) |
| `no_write_bypasses_the_trigger` | In `writes: :triggers`, `UPDATE`, `DELETE` **and `MERGE`** issued as raw SQL against the view all increment the usage counter. Catches the auto-updatability bypass (§10.3) |
| `noop_trigger_is_impossible` | Generated `INSTEAD OF` triggers always write; a mapping that would produce a no-op is a compile error, not an `UPDATE 1` (§10.3) |
| `view_survives_a_base_column_add` | A prepared statement against a generated view keeps working after the legacy owners add a column. Fails for any `SELECT *` view (§10.5) |
| `policy_filters_use_an_index` | `EXPLAIN` of a policy-filtered read shows no `Seq Scan` on the legacy base table (§10.7) |

## 9. Repository and release

| | |
|---|---|
| Name | `ash_strangler` — searchable, and it names the pattern rather than the mechanism. `ash_legacy` was considered and rejected as too broad; `ash_expand_contract` as too obscure. |
| Repo | `github.com/lukegalea/ash_strangler`, standalone. Not vendored here. |
| License | MIT, matching `ash`, `ash_postgres` and the rest of the ecosystem. |
| Version | `0.1.0`, README stating **alpha** plainly. By this repository's own tier rules ([thesis 6](../manifesto/06-reversibility.md)) it is **tier 3** until it has real deployments — isolated behind a seam, removable by deletion. |
| Hex | `mix hex.publish`, `ex_doc`, Spark DSL docs generated into `documentation/dsls/` via `mix spark.cheat_sheets`. |
| Installer | `mix igniter.install ash_strangler` adding the deps entry, the formatter `import_deps`, and the supervision-tree child. Standard for the ecosystem and the thing that makes a package feel finished. |
| CI | **Call the org's shared reusable workflow rather than hand-rolling one** — see §9.1. |

> ⚠️ **Correction, 2026-08-14.** An earlier version of this row said CI should run "`mix credo --strict` with
> `ash_credo`". That is wrong: `ash_credo` is a **consumer-facing** tool, for applications that *use* Ash. Extension
> repositories do not run it on themselves — they run plain `credo --strict`. Verified against `ash_credo`'s own README
> and the `mix.exs` of every vendored `ash_*` package.

### 9.1 The publication checklist

Researched 2026-08-14 against the 15 `ash_*` packages vendored in this repository's `deps/` (their shipped
`mix.exs`, `.formatter.exs`, `hex_metadata.config` and `README.md` — i.e. what was *actually published*, not what a
guide claims) plus the `ash-project` org on GitHub. **There is no template or scaffold repository**; the org's own
answer to "how do I start an extension" is to copy conventions from a sibling package, and `ash_state_machine` is the
cleanest small one to copy from.

This is scope for **step 8** in §11 — deliberately last, because most of it is only meaningful once the package's
shape has stopped moving.

**Must-have, in rough dependency order:**

| # | Item | State in `ash_strangler` today |
|---|---|---|
| 1 | Root `usage-rules.md`, listed in `package/0`'s `files:` | **done** |
| 2 | An `Info` module via `use Spark.InfoGenerator` — Spark's own documented convention is that `MyApp.MyExtension`'s introspection lives in `MyApp.MyExtension.Info` | **done** (`AshStrangler.Info`) |
| 3 | `.formatter.exs` with `spark_locals_without_parens` repeated under `export:` — this is what makes a *consumer's* `import_deps: [:ash_strangler]` format the DSL correctly | **done**, hand-maintained; should switch to `mix spark.formatter` |
| 4 | `documentation/dsls/DSL-AshStrangler.md` from `mix spark.cheat_sheets`, committed, added to `files:`, and wired into `docs/0` `extras:` with `Spark.Docs.search_data_for(AshStrangler.Resource)` | **missing entirely** |
| 5 | `mix.exs` aliases for `spark.formatter` and `spark.cheat_sheets`, with `docs:` chaining cheat-sheets first | missing |
| 6 | CI calling the shared workflow — `uses: ash-project/ash/.github/workflows/ash-ci.yml@main` with `secrets: HEX_API_KEY`, and `permissions:` for `contents`/`pages`/`id-token`/`security-events`. It provides format, `spark.formatter --check`, `spark.cheat_sheets --check`, `credo --strict` (plus a SARIF upload to code scanning), sobelow, dialyzer, `hex.audit`, `deps.unlock --check-unused`, doctor, changelog-lint, docs build/deploy, and the test matrix | **no `.github/` at all** |
| 7 | `package/0` `links:` including Discord and the Ash Elixir Forum category — universal across every package checked | missing |
| 8 | `docs/0` `groups_for_extras` and `groups_for_modules` (at minimum `Dsl:`, `Introspection: [AshStrangler.Info]`, `Internals: ~r/.*/`) | missing |
| 9 | README badge row — the CI, License, Hex version, Hexdocs and REUSE badges are word-for-word identical across packages | missing |
| 10 | `CHANGELOG.md` with an `Unreleased` section; the shared workflow has a `changelog-lint` job | missing |

**REUSE/SPDX is the one to decide deliberately.** Every `ash-project` source file opens with
`SPDX-FileCopyrightText` / `SPDX-License-Identifier` headers, files that cannot carry a comment get a sidecar
`<file>.license`, the canonical text lives in `LICENSES/MIT.txt`, and the shared workflow has a dedicated `reuse` job.
Hex does not require any of it. It is cheap to adopt and conspicuous to omit, so the choice is about whether the
package is presenting itself as ecosystem-native.

**Nice-to-have:**

- `lib/mix/tasks/ash_strangler.install.ex`, wrapped in `if Code.ensure_loaded?(Igniter) do`, with `igniter` added as
  `only: [:dev, :test]` — *never* a runtime dependency, which is also exactly the constraint ADR 0006 records for
  SaladUI. At minimum it should call `Igniter.Project.Formatter.import_dep(:ash_strangler)`, the step that makes DSL
  formatting work for consumers without them reading any documentation.
- Split `usage-rules.md` into a `usage-rules/` directory of topic files once it outgrows a few screens, as
  `ash_postgres`, `ash_graphql`, `ash_oban` and `ash_a2ui` do.
- `.github/CODE_OF_CONDUCT.md`, `FUNDING.yml`, and the PR/issue templates. Note these are only *checked* by the shared
  workflow's `community-files-check` job, which byte-compares them against `ash-project/.github` and fails on drift or
  on the wrong location — so copy them verbatim into `.github/`, or leave them out entirely rather than writing
  approximations.

**Already right, worth not breaking:** `ash_postgres` is declared `optional: true` here, and `ash_a2ui` ships a
bespoke CI job that proves its core compiles without its optional Phoenix dependency. The equivalent for this package
— proving the verifiers and `mix ash_strangler.check` still work with no data layer present — is worth adding when CI
exists, because that separation is a stated design goal (§2.4) and nothing currently enforces it.

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
4. **`upsert?: true` is available only when the mapping needs no `INSTEAD OF` trigger** (§10.2). If the compiler
   rejects it, the fix is to change the mapping, not to work around the verifier.
5. **Adding an attribute to a strangler-backed resource is a schema change**, because the view's `SELECT` list must
   grow. Regenerate.
6. **`mix ash_strangler.check` before every phase change**, no exceptions.

## 10. What is genuinely hard

Fourteen things. Some are solvable with care; five are not solved and would ship as documented limitations.

> §10.1–10.7 and §10.12–10.14 were **executed** — against PostgreSQL 17.10 (this repository's `devenv` server), or
> against a live `ash` — rather than inferred from documentation. Where a result contradicts what the source documents
> in `docs/` assume, the executed result wins. §10.8 and §10.12 additionally correct claims made *earlier in this
> document*, both found by building the thing rather than by rereading it.
>
> **§10.2 is the finding that reshapes the design.** It was written twice: the first version concluded upserts are
> simply unavailable on views, which is wrong. Upserts work fine on *auto-updatable* views and are destroyed by adding
> an `INSTEAD OF` trigger — so the trigger is not a free addition, it is a trade, and the DSL has to make that trade
> deliberately rather than always.

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

**The mirror-image trap:** a trigger that does the work and then returns `NULL` yields `INSERT 0 0` and zero
`RETURNING` rows *while the row is written*. Ecto reads zero affected rows as `Ecto.StaleEntryError`, so a successful
write surfaces as an error. Postgres's docs sanction `RETURN NULL` to mean "I modified nothing"; a generated trigger
must never use it.

### 10.2 The `INSTEAD OF` trigger is a trade, not an addition

This is the section that changed the design, and it is worth stating as a trade because that is what it is.

An **auto-updatable** view — single base table, no `DISTINCT`/`GROUP BY`/aggregates/window functions at the top level,
computed columns permitted — gets three things for free:

- **Upserts work.** `INSERT … ON CONFLICT (email) DO UPDATE … RETURNING …` resolves through to the base table's unique
  index and returns the real row.
- **`RETURNING` is correct**, because Postgres is doing the write.
- **`WITH CHECK OPTION` is enforced**, raising SQLSTATE 44000 on a row that escapes the view's own `WHERE`.

Adding an `INSTEAD OF` trigger to that same view **silently removes all three**, and the removal is not announced:

| | auto-updatable view | + `INSTEAD OF` trigger |
|---|---|---|
| `ON CONFLICT (col) DO UPDATE` | works | `ERROR: there is no unique or exclusion constraint matching the ON CONFLICT specification` |
| `ON CONFLICT DO NOTHING` | works | **accepted, then inert** — the conflict escapes as a raw unique violation from inside the trigger |
| `ON CONFLICT ON CONSTRAINT name` | `ERROR: constraint … for table "v" does not exist` | same |
| `RETURNING` | real stored values | whatever the trigger returned (§10.1) |
| `WITH CHECK OPTION` | enforced, SQLSTATE 44000 | **silently ignored**, no warning at `CREATE VIEW` time |
| statement-level `AFTER` trigger on the view | **never fires** | fires |
| writes to computed columns | rejected by Postgres | accepted, trigger decides |
| arbitrary mapping / logging / usage counter | impossible | possible |

`ON CONFLICT ON CONSTRAINT` fails on *both* — so an upsert against any view must use a column-list conflict target,
never a constraint name. In Ash terms, `upsert_identity` must resolve to columns.

**The design consequence is that triggers must be derived, not policy.** The plan's earlier instinct — "generate all
three `INSTEAD OF` triggers in `:dual_write` so nothing takes an ungoverned path" — would destroy upsert support on
every resource, including the authentication resources that need it most. The correct rule is:

> Generate `INSTEAD OF` triggers **only for the operations the mapping actually requires them for**, and make the
> requirement a derived property of the DSL: a source that is one table with only plain column mappings and no
> constants needs no triggers at all; a computed writable mapping, a multi-table source, or a usage counter each force
> one.

`VerifyNoUpserts` accordingly becomes conditional: it rejects `upsert?: true` only on resources whose mapping forced a
trigger, and the error message says *which mapping* caused it. That turns an unexplainable limitation into a
tractable one — remove the mapping that forced the trigger, or move the action past cutover.

The residual hazard is §10.3: not generating triggers means writes reach the base table by a path the mapping did not
describe. There is no configuration that avoids both. **This is the sharpest unresolved tension in the design**, and
the honest resolution is that the DSL surfaces the trade (`writes: :auto | :triggers`) with a derived default and a
documented consequence, rather than picking silently.

The remaining open question is behavioural: **how many Ash and `ash_authentication` paths silently depend on
upserts**, and therefore how expensive the trigger side of the trade actually is. §11, spike 4.

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

The instinct is to always generate the full set of `INSTEAD OF INSERT/UPDATE/DELETE` triggers in `:dual_write` so no
write can take an ungoverned path — and adding an `INSTEAD OF UPDATE` trigger does both route the write *and* unlock
computed-column updates (verified: with the trigger present, `UPDATE … SET full_name = …` no longer errors). **But
§10.2 shows that costs upserts, correct `RETURNING` and `WITH CHECK OPTION`, and it does so silently.** There is no
setting that closes the bypass and keeps the free behaviour. The DSL surfaces the choice; it does not make it.

Two further hazards on the trigger side of the trade:

**A trigger that returns `NEW` without writing anything reports `UPDATE 1`.** Verified — a no-op `INSTEAD OF UPDATE`
trigger that only raised a notice returned a successful row count. Silent data loss with a success response is the
exact failure mode this exercise exists to prevent, and it is why §5.3 makes an unmapped writable attribute a
*compile* error rather than a runtime warning.

**Statement-level triggers on a view fire only when a row-level `INSTEAD OF` trigger handles the action.** On an
auto-updatable view, a statement-level `AFTER INSERT` trigger **never fires at all** — no error, no warning. So the
usage counter (§7.1) cannot be a statement trigger on the view; it has to live inside the `INSTEAD OF` function, and
therefore does not exist on the auto-updatable path. **In `writes: :auto` mode there is no usage evidence**, which
means §7.1's "is the legacy write path dead yet" answer is unavailable exactly where triggers were avoided. That is a
real cost of the cheap option and belongs on the DSL option's doc string.

Finally, do not reimplement the updatability rules. Postgres exposes them:
`pg_relation_is_updatable(regclass, bool)` returns a per-relation bitmask and
`pg_column_is_updatable(regclass, attnum, bool)` a per-column boolean. `mix ash_strangler.check` should call these
against the deployed view and compare with what the DSL believed, which catches drift a compile-time verifier cannot.

### 10.4 Constraint errors carry the base table's name

Verified: a duplicate through the view raises

```
ERROR:  duplicate key value violates unique constraint "index_users_on_login"
CONTEXT: SQL statement "INSERT INTO legacy.users …"  PL/pgSQL function strangler.users_ins() line 3
```

— the *base table's* index name, identical for both view flavours; the view's own name never appears. Ash derives the
name it expects from the resource's configured table (`ash_postgres/lib/data_layer.ex:3723` builds it,
`:3395` matches it), so a resource pointing at `strangler.users` expects `users_email_index` while Postgres reports
`index_users_on_login` — no match, no `InvalidAttribute`, and a raw `Postgrex.Error` escapes.

Three fixes, and the third is the one a code generator should take:

1. `identity_index_names` per identity — the intended escape hatch, but it must be populated by hand.
2. `unique_index_names` for non-identity indexes.
3. **Name the base-table indexes to match what the view-backed resource expects.** In the expand phase the extension
   is already writing DDL against the legacy schema, so it controls both sides and can rename the index to the derived
   name. Correct by construction beats configuration that can be forgotten.

Before the expand phase, option 1 is all there is, and the verifier catches only the indexes the user declared.
Introspecting `pg_indexes` at compile time would close the gap; compile-time database access is a hard no for a
library, so `mix ash_strangler.check` compares declared indexes against `pg_indexes` at *runtime* instead.

Two related traps:

**`WITH CHECK OPTION` violations are not mappable at all.** They raise SQLSTATE **44000** with *no* constraint name
and *no* table name. If the compatibility view uses a check option for tenant scoping — and it is tempting, because
`WHERE organization_id = …` in the view is a neat isolation guarantee — the resulting error cannot be routed to a
field. It must be handled as a distinct case. And on a trigger-updatable view the check option is **silently
ignored entirely** (§10.2), which turns a neat isolation guarantee into no guarantee at all with no warning.

**Row-level `BEFORE`/`AFTER` triggers cannot exist on a view** (`ERROR: "users" is a view / Views cannot have row-level
BEFORE or AFTER triggers`), nor can transition tables. So the notify trigger must live on the base table — which the
design already assumed — and there is no per-row hook on the view itself.

### 10.5 Replacing a view is nearly always a `DROP`, and live connections notice

Two constraints that together decide how phase transitions can be shipped.

**`CREATE OR REPLACE VIEW` is append-only.** The replacement must produce the same columns, in the same order, with
the same types; it may only *append*. The expressions behind them can change completely. So a mapping edit that
renames an attribute, changes its type, drops it, or reorders the select list cannot be an `OR REPLACE` — it is a
`DROP VIEW` plus `CREATE VIEW`, which takes a new OID and cascades to dependents. Since §10.8's `custom_statements`
ordering already emits changed statements as down-then-up, this is at least consistent — but it means the cheap path
(`CREATE OR REPLACE`) is available only for expression changes, and the plan should not assume it more broadly.

**Changing a view's shape breaks live prepared statements.** Verified on 17.10: with a prepared statement open against
a view, adding a column via `CREATE OR REPLACE VIEW` and re-executing gives
`ERROR: cached plan must not change result type` (SQLSTATE `0A000`). Postgrex recovers automatically — it evicts the
statement from its per-connection cache on `:feature_not_supported` and re-prepares
(`postgrex/lib/postgrex.ex:317-341`) — **except when the connection is already in a failed transaction**, where the
guard skips the retry and the error propagates. A view swap landing mid-`Repo.transaction/1` therefore aborts that
transaction rather than self-healing.

One design rule falls out and it is cheap to follow: **generated views must enumerate their columns explicitly, never
`SELECT *`.** Verified — a prepared statement against an explicit-column view survived a column being added to the
*base* table; the `SELECT *` equivalent did not. Since a legacy schema is by definition one whose owners still add
columns, `SELECT *` in a compatibility view converts every one of their migrations into a 0A000 storm across the
connection pool. The DSL's design already forces explicit columns; this is why that is not merely tidiness.

### 10.6 Notifications are best-effort, and an audit log is not

Verified against PG 17.10:

- **`NOTIFY` does not fire on rollback.** A `pg_notify` inside a rolled-back transaction delivers nothing. Correct, and
  what you want.
- **Postgres collapses duplicate notifications within a transaction.** Two identical `(channel, payload)` notifies in
  one transaction deliver **once**; a third with a different payload delivers separately. Since the design's payload is
  just the primary key, a row updated twice in one transaction produces one event. That is fine for a re-read-based
  listener and fatal for anything that counts events. **You cannot use `pg_notify` to measure write volume.**
- **Savepoint rollback discards notifications too**, so `pg_notify` is safe inside an `Ecto.Multi` or any
  subtransaction — a notify issued after a savepoint and rolled back to it is not delivered, while one issued before it
  is.
- **The payload ceiling is 7999 bytes, and exceeding it is a hard error rather than a truncation.** 8000 fails with
  `ERROR: payload string too long` (SQLSTATE 22023), measured in **bytes, not characters**, so UTF-8 expansion counts.
  The channel name limit is 63 bytes. Either error aborts the *legacy application's transaction*. A notify trigger that
  builds its payload from row data is therefore a latent outage in the legacy app, and the design's key-only payload is
  not merely an optimization; it is the
  only safe choice.
- At-most-once, in-memory, not persistent. Nothing survives a restart; a disconnected listener misses everything sent
  while it was away; there is no replay and no acknowledgement. The queue defaults to 8 GB
  (`max_notify_queue_pages`, `postmaster` context) and `pg_notification_queue_usage()` reports the fraction in use —
  monitor it, because a full queue fails the transaction that issued the `NOTIFY`, which is to say it fails the legacy
  application.

All of which is entirely fine for LiveView reactivity and cache invalidation, and entirely unacceptable for a
compliance audit trail. Where a complete record of legacy writes is required, the mechanism has to be a synchronous
trigger inserting into an events table inside the legacy transaction — coupling the legacy app's availability to the
audit table's health. A real tradeoff with no right answer; the package should support both and refuse to pick.

Two operational notes that belong in the README rather than being discovered:

- **`LISTEN` is session-scoped and therefore does not work under pgbouncer transaction or statement pooling.** The
  listener needs a dedicated connection that bypasses the pooler. This is standard for `Postgrex.Notifications` setups
  but it is a deployment requirement, not a detail.
- **Never interpolate untrusted input into a channel name.** Postgrex has had three channel-name escaping CVEs in
  recent releases (fixed through 0.22.4). Channel names in this design are derived from resource module names, which
  is safe — keep it that way rather than making them configurable strings.

### 10.7 Policy filters over views — less bad than expected, but sharply bounded

Ash policies produce `WHERE` clauses, so the question is whether Postgres pushes them into the base table. Measured:

| View shape | Filter | Plan |
|---|---|---|
| single table | plain column | `Index Scan using users_pkey` |
| `LEFT JOIN` to a second table | plain column | `Index Scan using users_pkey` under a hash join |
| `DISTINCT` | plain column | `Index Scan` **below** the `Unique`/`Sort` |
| `GROUP BY … count(*)` | the grouping key | `Index Only Scan` below `GroupAggregate` |
| `row_number() OVER (…)` | plain column | `Subquery Scan` + `Filter` **above** `WindowAgg` — full scan |
| single table | **computed column** | `Seq Scan` with the expression in `Filter` |

So joins, `DISTINCT` and aggregates on grouping keys are all fine — the pessimism in the source documents is
misplaced. **The two real killers are window functions and filters on computed columns.** The second is the one that
matters here, because `owning_business_unit_id` is a computed column in the reference-app design and `RoleGrant`
filters on exactly that. Every policy-relevant column must therefore be either a real column or backed by an
expression index.

The extension can emit expression indexes, but it cannot know which columns policies will filter on. The workable rule:
**derive an expression index for every attribute that appears in an `identity`, a `belongs_to` source, or the
multitenancy attribute**, document that anything else under load needs the expand step, and make §8's suite include an
`EXPLAIN`-based assertion so a regression is a test failure rather than a pager.

### 10.8 Migration ordering

`custom_statements` are diffed by name and ash_postgres's own documentation is explicit that it cannot determine
ordering, that all `down`s run before all `up`s, and that changing a statement regenerates it as down-then-up. For a
single view that is fine. For a view another view depends on, the `DROP` fails or needs `CASCADE`; for a trigger whose
function is in a different statement, the ordering is wrong.

Mitigations: use `CREATE OR REPLACE` where Postgres allows it so the down-then-up cycle is avoided entirely.
`CREATE OR REPLACE VIEW` cannot change a column's type or drop a column, so this only goes so far. **Unresolved for
cross-resource dependencies**, and the fallback is that the package generates the statements and a human orders the
migration — which is a defensible position for DDL this consequential, but it is not the "fully derived" story.

> ⚠️ **Corrected 2026-08-14, while building step 4.** This section previously proposed "emit one statement per resource
> containing all of its DDL (fewer, larger statements order themselves internally)". **That is impossible.** An
> `AshPostgres.Statement` is rendered as a single `execute("…")`;
> `Ecto.Adapters.SQL.execute_ddl/4` (`deps/ecto_sql/lib/ecto/adapters/sql.ex:1237`) wraps the string and passes it to
> `query!/4`, the *extended* protocol, which rejects multiple commands outright:
>
> ```
> ERROR 42601 (syntax_error) cannot insert multiple commands into a prepared statement
> ```
>
> So a statement holding a `CREATE FUNCTION` **and** its `CREATE TRIGGER` fails at `mix ash.migrate` time. Discovered
> the same way everything else in §10 was — by running it, here in the test harness, which fails at fixture-install
> time and therefore before any test can pass.
>
> The rule is the opposite of what was written: **exactly one SQL command per statement.** Two consequences follow, both
> now implemented:
>
> 1. **Order matters and must be forced.** `Spark.Dsl.Transformer.add_entity/4` **prepends** by default
>    (`deps/spark/lib/spark/dsl/transformer.ex:275`), which reverses a dependency-ordered list and fails on the first
>    migration. `type: :append` is required.
> 2. **`down`s must be order-independent**, because every `Remove` runs before every `Add`, in list order — the reverse
>    of what teardown needs. Functions drop `CASCADE`; trigger drops are wrapped in a `DO $$ … $$` block (still one
>    command) guarded by `to_regclass`, because `DROP TRIGGER IF EXISTS … ON <view>` still raises if the *view* is
>    already gone — `IF EXISTS` guards the trigger, not the relation.
>
> A `DO $$ … $$` block is the general escape hatch here: arbitrary procedural logic, still a single command.

### 10.9 Phase transitions are stateful, and Spark verifiers are read-only

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

### 10.10 Passwords, and everything else the mapping cannot reach

Legacy password hashes cannot be converted. Encrypted columns cannot be re-keyed by a view. Serialized Ruby YAML
columns cannot be usefully projected. Every real migration has at least one of these, and none of them are schema
mapping problems.

The correct posture is for the package to be *loudly incomplete* about it: `writable? false` with a mandatory
`because:` is the mechanism, and the docs should carry a worked example of the password case specifically, ending in
"and now you write a custom hash provider by hand." A tool that leaves you holding the hard part is still valuable.
A tool that implies there is no hard part is worse than nothing.

### 10.11 It might not be worth building

Stated last because it is the honest conclusion of §2 and must survive the enthusiasm of the preceding nine sections.
The mechanism — views and `INSTEAD OF` triggers — is well understood and hand-writable. What the package adds is
derivation, verification, and phase management. If the verification (§6.3) and the pre-flight check (§6.4) are the
valuable parts, and the SQL generation is the risky part, then **the honest minimum viable package is
`mix ash_strangler.check` plus the verifiers, with the SQL left to the user.** That is a much smaller thing and it
delivers most of the value on the first day.

The argument on the other side got stronger while this document was being written, and it should be recorded fairly.
§10.1, §10.2, §10.3 and §10.5 are exactly the kind of trap a generator exists to eliminate. The obvious trigger body
returns nulls and reports success. Adding a trigger silently disables upserts and `WITH CHECK OPTION`. Not adding one
leaves an ungoverned write path. A `SELECT *` view turns somebody else's migration into a connection-pool outage.
None of these is discoverable by reading; each was found by running SQL, and one of them reversed a decision already
written down in this document. **A tool whose entire value is "never emits the version that silently loses data" is a
defensible tool** — and that argues for generating the SQL rather than documenting how to write it.

That is an argument, not a decision. The gate in §11 is what settles it.

### 10.13 The derived primary key breaks every `create` until it is marked generated

Found 2026-08-14 while building step 4. §5.4 anticipated the *shape* of this — "the id is derived from the legacy key,
so it cannot be generated client-side" — and prescribed

```elixir
attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
```

which does not work. Ash requires any `allow_nil? false` attribute that has neither a supplied value nor a default, so
**every create fails with `attribute id is required`** before a query is issued. `writable? false` does not exempt it;
it just guarantees nobody can satisfy the requirement either.

The fix is `generated? true`, which tells Ash the data layer produces the value and to read it back rather than demand
it. That is not a workaround — the view genuinely generates the column.

Implemented as `AshStrangler.Transformers.MarkKeyGenerated` rather than left to the user, because the DSL already says
which attribute the key is (`key :id, from: "id", …`); making the author restate it as an unrelated-looking flag on the
attribute means the penalty for forgetting is a confusing runtime error on every create that points nowhere near the
mapping.

One implementation note worth recording: `Spark.Dsl.Transformer.replace_entity/4`'s default matcher compares
`__identifier__`, which `Ash.Resource.Attribute` does not have, so it **raises** rather than failing to match. Pass an
explicit matcher.

### 10.14 Ash's own type casting diverges from what the legacy application writes

Found the same day, by the dual-write round-trip property failing on `" leading"` coming back as `"leading"`.

`Ash.Type.CiString` defaults to `trim?: true`, so a value written *through Ash* is trimmed before it reaches SQL, while
the identical value written directly by the legacy application is not. During `:dual_write` the two paths therefore
disagree about what is stored, and nothing raises. The same applies to any Ash type with normalising constraints.

**This is not a defect this package can fix, and it should not try.** It is the legitimate behaviour of the modern
model; the whole point of adopting Ash is that it validates and normalises. But it means "the two write paths agree" is
*false by construction* for some columns, which matters for two things already planned:

- §8.4's differential dual-write test cannot assert byte-identical databases for such columns. It has to compare
  against what each path is *supposed* to store, not against each other.
- The reconciler (§6.4, step 6) will report these as drift forever unless it knows to normalise before comparing.
  That is the reconciler's problem to solve and it should be designed knowing this exists — otherwise its first
  production run is a wall of false positives, which is how a drift detector gets switched off.

### 10.12 A naive `timestamp` cast to `timestamptz` is session-dependent — and silently so

Found 2026-08-14 while building step 3's round-trip harness, executed against PG 17.10. Not anticipated anywhere above,
and it is the same species as §10.1: the generated SQL is accepted, runs, returns a plausible value, and the value is
wrong.

A mapping written the obvious way —

```elixir
map :archived_at, "deleted_at", cast: :timestamptz
```

— generates `(deleted_at)::timestamptz`. When the legacy column is `timestamp` *without* time zone, which is what Rails,
Django and most 2010s schemas store, **that cast interprets the naive value as wall-clock time in the session's
`TimeZone` GUC** and converts to an instant accordingly. Verified, same stored row, same view, three sessions:

| session `TimeZone` | resulting UTC instant |
|---|---|
| `UTC` | `2024-06-15 12:00:00Z` |
| `America/New_York` | `2024-06-15 16:00:00Z` |
| `Australia/Lord_Howe` | `2024-06-15 01:30:00Z` |

Ten and a half hours of drift between two connections reading the same row through the same view. Nothing in the view
controls it: `TimeZone` is per-session, so a background job, a psql session, a replica with a different default, or a
pooled connection that inherited a `SET TimeZone` all read different instants. This is worse than the `WITH CHECK
OPTION` case in §10.2, because there is no error and no missing behaviour to notice — just a timestamp that is quietly
wrong by a fixed offset.

Two related behaviours, also verified, also silent: a nonexistent local time (`2024-03-10 02:30` in the spring-forward
gap) is normalized rather than rejected, and an ambiguous one (`2024-11-03 01:30`, which happens twice) resolves to one
of the two occurrences without complaint. There is no error path a test could assert on.

**Not fixed, deliberately, and this is the fourth documented limitation.** The correct SQL is
`(deleted_at AT TIME ZONE 'UTC')`, which is deterministic — but only if the legacy column really is UTC. The generator
cannot know that: it is a fact about the legacy application, not about the schema, and guessing wrong moves every
timestamp in the system by a fixed offset. The options, in preference order:

1. **Make the DSL ask.** `cast: :timestamptz, from_zone: "UTC"` generating `AT TIME ZONE`, and *refuse to compile* a
   naive-to-`timestamptz` cast that does not say which zone. That is the `because:`-style move this package already
   makes elsewhere: force the ambiguity to be resolved in the mapping, where it is reviewable, rather than inherited
   from whatever connection happens to run the query.
2. Emit `AT TIME ZONE 'UTC'` by default and document it. Right for the majority; silently wrong for everyone else.
3. Leave it and document. Cheapest, and inconsistent with the rest of the design.

Option 1 is where this should land, and it is step 4 work — the DSL change is small, but it belongs with the write path
rather than bolted onto a shipped read path. Pinned in the meantime by a regression test
(`AshStrangler.RoundTripTest`, tagged `:hazard`) that asserts the drift *exists*, so the day it changes, something
fails.

## 11. Sequencing, and the spikes that come first

All six spikes — the original three plus the three the SQL spike raised — are now answered: three from source reading,
one from executing SQL against PG 17.10, one from executing Elixir against a live `ash_authentication` app, and one
from reproducing a crash directly against `Ash.Notifier.PubSub`. That is unusual for a plan at this stage and it is the
reason the risk assessment above is specific rather than hedged.

1. ~~**Can a third-party Spark transformer add entities to `[:postgres, :custom_statements]`?**~~ **Yes.**
   `add_entity/4` is ungated and keyed on section path only; `build_entity/4` validates against the target extension's
   schema; `VerifyEntityUniqueness` checks the names. Unprecedented in a data-layer section, but mechanically sound.
   §6.1.
2. ~~**Does `RETURNING` behave as assumed?**~~ **Yes, and the naive trigger silently returns nulls.** §10.1.
3. ~~**Does `INSERT … ON CONFLICT` work against a view?**~~ **Yes on an auto-updatable view with a column-list
   conflict target; no once an `INSTEAD OF` trigger exists, where `DO NOTHING` is accepted and then inert.** Never
   with `ON CONSTRAINT`. §10.2 — and this reversed a design decision, which is the argument for running spikes before
   writing plans rather than after.

Three questions the SQL spike *raised* and did not answer at the time, all of which preceded step 2 (step 1 — the
verifiers and `mix ash_strangler.check` — needed none of them and shipped first, 0.1.0):

4. ~~**How many Ash and `ash_authentication` code paths silently depend on upserts?**~~ **Answered 2026-08-14, against
   `ash_authentication` 4.14.1 and this application.** The answer is sharper than "some", and it partitions cleanly:

   | Path | Upsert | Migratable with `INSTEAD OF` triggers |
   |---|---|---|
   | `password` strategy | none — register is a plain create | **yes** |
   | `oauth2` / `oidc` strategies | **enforced** | **no** |
   | `UserIdentity` resource | unconditional `upsert?: true` | **no** |
   | This app's own resources | 6 of them, 5 in `Security` | no |

   The OAuth2 case is not incidental. Its transformer *validates* the requirement —
   `validate_field_in_values(action, :upsert?, [true])` plus a required `upsert_identity` — so an OAuth2 register action
   **cannot be defined without an upsert**. There is no configuration that avoids it, which means the trigger path and
   OAuth2 are mutually exclusive rather than merely awkward together.

   Consequences for the design:

   - **Password-only authentication can migrate with triggers.** This is the common case for a legacy monolith and it
     is the one the reference app demonstrates.
   - **Adding OAuth2 to a resource already on the trigger path is a breaking change**, and the failure is a compile-time
     transformer error rather than a runtime surprise — which is the good outcome, but the extension should say so in
     the `writes: :triggers` documentation rather than letting people discover it.
   - `VerifyNoUpserts` must name the *strategy* when the offending upsert comes from `ash_authentication`, because
     "action `:register_with_oauth2` requires upserts" is not actionable without knowing it was the strategy that
     required it.
   - The six upsert actions in this application are all join tables and catalogue rows — the resources least likely to
     need strangling. That is luck, not design, and it should not be generalized to other applications.
5. ~~**Can `ecto_watch` install triggers on arbitrary relations in a non-default schema**, or is it bound to Ecto
   schemas it owns?~~ **Answered 2026-08-14, by reading `cheerfulstoic/ecto_watch` main @ github.com (`lib/ecto_watch/options/watcher_options.ex`,
   `lib/ecto_watch/watcher_server.ex`).** Yes, unambiguously — this is not an accident of implementation, it is a
   documented, validated second path. `WatcherOptions.SchemaDefinition.new/1` has two clauses: one takes an Ecto
   schema module and introspects it; the other takes a **plain map** —
   `%{schema_prefix:, table_name:, primary_key:, columns:, association_columns:, column_map:}` — with no Ecto schema
   involved at all, validated by its own `NimbleOptions` schema and requiring only a `label:` option alongside it (the
   trigger/function/channel names are derived from the schema module in the Ecto-schema path, so the map path needs an
   explicit name to derive them from instead). `schema_prefix` defaults to `:public` but accepts any schema name as a
   string or atom, and the generated DDL is schema-qualified throughout —
   `CREATE OR REPLACE TRIGGER … ON "#{schema_prefix}"."#{table_name}"`, function created as
   `"#{schema_prefix}".#{function_name}` (`watcher_server.ex`). It also branches on
   `EctoWatch.DB.supports_create_or_replace_trigger?/1` (`major_version(repo) >= 14`) to fall back to `DROP TRIGGER IF
   EXISTS` + plain `CREATE TRIGGER` below PG 14 — `CREATE OR REPLACE TRIGGER` is itself a PG 14 feature, which lines up
   exactly with this plan's own PG 14 floor. **Consequence: `ecto_watch` can watch `legacy.users` directly, with no
   Ecto schema module for it at all**, which confirms §2.1's premise and means the notify/listen half of this design
   really can be "integrate `ecto_watch`", not "reimplement it because it can't reach the legacy schema."
6. ~~**What does `Ash.Notifier.PubSub` do with a synthesized notification that has no changeset?**~~ **Answered
   2026-08-14, executed against `ash` 3.31.3 (`deps/ash/lib/ash/notifier/pub_sub/pub_sub.ex`) rather than inferred.**
   Worse than the hedge above: it does not merely fail to resolve, **it raises**. A `%Ash.Notifier.Notification{}`
   with `changeset: nil` and a topic containing `:_pkey` on a create-type action raises
   `** (KeyError) key :resource not found in: nil` (`Ash.Resource.Info.primary_key(notification.changeset.resource)`,
   `pub_sub.ex:588`); the same with `:_tenant` on an update-type action raises
   `** (KeyError) key :to_tenant not found in: nil` (`notification.changeset.to_tenant`, `pub_sub.ex:549`). Both were
   reproduced directly: an ETS-backed resource with `notifiers: [Ash.Notifier.PubSub]`, a hand-built notification with
   `changeset: nil`, calling `Ash.Notifier.PubSub.notify/1`. **It is not only `:_pkey`/`:_tenant`** — for an
   `:update`/`:destroy` action, *any* plain-attribute topic key also dereferences `notification.changeset.data` to
   compare before/after values, so it crashes too; only a `:create` notification with a topic built from literal
   strings or plain attributes already present on `data` survives with `changeset: nil`. Since `notify/1` dispatch is
   synchronous in the calling process (§6.4), this crash lands **in the listener process**, on every legacy write that
   matches such a publication — not a degraded bridge, a crashing one. The fix was verified too, not just proposed: a
   *minimal* synthesized `%Ash.Changeset{resource:, action_type:, data:, to_tenant:}` (no real changeset construction,
   no action running) is sufficient — both crashes disappear and the topics resolve correctly
   (`thing:updated:tenant-x`, `thing:created:<uuid>`). **Consequence: synthesizing a changeset in the bridge is not an
   enhancement, it is a correctness requirement for any publication using `:_pkey`, `:_tenant`, or an update/destroy
   topic — the README's hedge should become a firm "the bridge always synthesizes one," not a caveat.**

Then, in order:

| Step | Deliverable | Why this order | State |
|---|---|---|---|
| 1 | `mix ash_strangler.check` + the verifiers, no SQL generation | Standalone value, zero risk, answers §10.11 | **done** 2026-08-14 |
| 2 | View generation, `:read_from_legacy` only | The smallest useful generator | **done** 2026-08-14 |
| 3 | Round-trip property test harness | Before write generation, not after | **done** 2026-08-14 |
| 4 | `INSTEAD OF` triggers, `:dual_write` | The risky part, with the oracle already in place | **done** 2026-08-14 |
| 5 | Listener + notifications | Independent; genuinely useful on its own | **done** 2026-08-14 |
| 6 | Backfill + reconciler | | **done** 2026-08-14, with pgroll's flag column (§6.4) |
| 7 | `:read_from_new` reversal, `:decommissioned` | The one-way door, built last | **done** 2026-08-14 |
| 8 | Publication audit against the ecosystem's extension conventions — §9.1 | Last, because most of it only settles once the package's shape has | **done** 2026-08-14 |

**Step 1 is the decision gate.** If it is useful on its own and steps 2–4 look worse in the writing than they do in
this document, ship step 1 as the whole package and write a guide for hand-rolling the rest. That is a legitimate
outcome, and pre-committing to it is the main reason this plan exists in written form before any code.

> **The gate was passed, and steps 3–4 are why it is worth recording how.** The harness (real Postgres, no mocks; a
> generated view installed by executing the generator's own output; StreamData over an adversarial value space) found
> §10.12 within an hour of existing — a silent, session-dependent timestamp error in SQL that had already been written,
> reviewed and committed. Step 4 then found three more the same way: §10.8's central mitigation was impossible,
> §10.13's prescribed primary-key declaration broke every create, and §10.14 surfaced a dual-write divergence nobody
> had considered. All four were found by *executing* generated SQL, none by rereading the plan.
>
> The suites also prove they can fail. Mutating one character of the generated key expression (`':'` → `'!'`) is caught
> by four tests; dropping `AT TIME ZONE` from the write path is caught by one — and *only* by the test that shifts the
> session zone, because under the default UTC session the wrong implementation accidentally produces the right answer.
> That asymmetry is the argument for adversarial fixtures over convenient ones.
>
> That is the evidence §10.11 asked for.
