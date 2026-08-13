# Plan — AshStrangler in the reference application

- **Status:** **DEFERRED.** Nothing here is built. Do not begin until the current phases are complete — Organization
  and tenancy (Phase 5), hierarchy security (Phase 6). Written now because designing the demonstration is how you find
  out whether the extension design is honest, and because the conflicts in
  [§4](#4-where-it-collides-with-the-platform) are findings about *this repository* whether or not the extension is
  ever built.
- **Date:** 2026-08-13
- **Depends on:** [`ash-strangler.md`](ash-strangler.md), at least through its read-model phase. Two steps
  ([§5](#5-the-migration-story-step-by-step), steps 0 and 1) do not.

---

## 1. Why the reference app needs a legacy schema at all

Every resource in this repository was written by us, against a schema we generated from a corpus we chose, with
primary keys of a type we picked. `AshEnterprise.Platform.Resource` supplies `organization_id`,
`owning_business_unit_id`, `owner_id`, `version_number`, `state_code` and eight provenance columns to every resource,
and every resource has them because we made sure it did.

That is a closed loop. The manifesto's central claim — declare the cross-cutting concerns once, derive everything else
— has so far only been tested against data that was designed to be derived. The interesting question is what happens
when it meets data that was not:

- A table whose primary key is `serial`, not `uuid`.
- Rows with no tenant, because the application that wrote them was single-tenant.
- Rows with no owner, because the application that wrote them had two roles and a boolean.
- Passwords hashed with an algorithm no current library will verify.
- Writers that are not Ash, and therefore not audited, and therefore holes in a log we describe as complete.

A greenfield reference app cannot surface any of that. It can only demonstrate that the derivation works on inputs
shaped for it. The legacy schema is the adversarial input.

## 2. The legacy schema

The demo schema is a 2010-era Rails 2.3 application: `restful_authentication` for identity, an `acl9`-shaped role
table, and a `permissions` table someone bolted on in 2013 and nobody has understood since. It is not a caricature.
Every ugly detail below exists because it was the normal thing to do at the time.

It lives in the Postgres schema `legacy`, in the **same database** as the application. That choice is deliberate and
is argued in the extension plan: one database means one transaction, and one transaction removes the entire class of
dual-write failure that makes these migrations dangerous.

```sql
CREATE SCHEMA legacy;

-- The closest thing the legacy app has to an org chart. Used for report
-- filtering, never for authorization.
CREATE TABLE legacy.companies (
  id         serial PRIMARY KEY,
  name       varchar(255) NOT NULL,
  parent_id  integer REFERENCES legacy.companies(id),
  created_at timestamp,          -- no time zone. Written in the server's local time.
  updated_at timestamp
);

-- restful_authentication's generated users table, essentially verbatim,
-- plus the columns that accreted over fifteen years.
CREATE TABLE legacy.users (
  id                        serial PRIMARY KEY,
  login                     varchar(40),
  email                     varchar(100),
  first_name                varchar(40),
  last_name                 varchar(40),
  crypted_password          varchar(40),   -- SHA1(salt + password), 40 hex chars
  salt                      varchar(40),
  remember_token            varchar(40),
  remember_token_expires_at timestamp,
  activation_code           varchar(40),
  activated_at              timestamp,
  state                     varchar(20) NOT NULL DEFAULT 'passive',
  deleted_at                timestamp,     -- acts_as_paranoid
  company_id                integer REFERENCES legacy.companies(id),
  manager_id                integer REFERENCES legacy.users(id),
  created_at                timestamp,
  updated_at                timestamp
);

CREATE UNIQUE INDEX index_users_on_login ON legacy.users (login);
CREATE        INDEX index_users_on_email ON legacy.users (email);  -- NOT unique. Case-sensitive.

-- acl9-shaped roles: a role can be global (both authorizable columns NULL)
-- or scoped to one record of one class.
CREATE TABLE legacy.roles (
  id                serial PRIMARY KEY,
  name              varchar(40),
  authorizable_type varchar(40),
  authorizable_id   integer
);

-- HABTM join table. No primary key. No timestamps. Rails did not add them.
CREATE TABLE legacy.roles_users (
  role_id integer REFERENCES legacy.roles(id),
  user_id integer REFERENCES legacy.users(id)
);

-- Added in 2013. `scope` was added in 2016 and is NULL on 94% of rows.
CREATE TABLE legacy.permissions (
  id            serial PRIMARY KEY,
  role_id       integer REFERENCES legacy.roles(id),
  subject_class varchar(60),   -- 'Invoice', 'PurchaseOrder', 'Report'
  action        varchar(20),   -- 'read', 'edit', 'destroy', 'manage'
  scope         varchar(20)    -- NULL | 'own' | 'company'
);
```

### The details that matter

Six properties of this schema are load-bearing for the demonstration. Each maps to a specific claim the platform makes.

| Legacy property | The platform assumption it breaks |
|---|---|
| `id serial` | Every FK the base resource adds is `:uuid` |
| No tenant column | `organization_id` is `allow_nil?: false` |
| `company_id` is not a security boundary | `owning_business_unit_id` drives `:local` and `:deep` depth |
| `index_users_on_email` is neither unique nor case-insensitive | `identity :unique_email` on a `:ci_string` |
| `crypted_password` is SHA1 + salt | `AshAuthentication.BcryptProvider` |
| `roles_users` has no primary key | Ash resources require one |

Plus two that are not schema properties at all.

**The legacy application keeps writing.** That is what breaks the audit log, and it is the hardest problem in the whole
exercise (§4.8).

**A view cannot arbitrate an upsert.** `AshAuthentication` needs upserts for several flows and they are unavailable
against a view — verified, §4.10. This is the constraint that decides the *order* of the migration, and it is invisible
until you try it.

## 3. How it gets created and seeded

Three files, one mix task, and a hard rule.

```
priv/legacy/
  schema.sql          -- the DDL above, verbatim
  seed.sql            -- deliberately messy data
  README.md           -- what this is, and why Ash must not touch it
```

```elixir
# lib/mix/tasks/ash_enterprise.legacy.setup.ex
defmodule Mix.Tasks.AshEnterprise.Legacy.Setup do
  @moduledoc """
  Creates and seeds the simulated legacy schema.

  Plain SQL applied with `psql`, NOT an Ecto migration and NOT an Ash resource.
  That is the point: the whole exercise is about a schema this application does
  not own, and the moment it appears in `priv/repo/migrations` the demo is
  lying about the situation it demonstrates.
  """
end
```

**The rule: `mix ash.codegen` must never emit a statement that touches `legacy.*`.** Enforcing it is a test, not a
convention — a migration-diff test that fails if any generated migration mentions the `legacy` schema. Until the expand
phase (step 4 below), which touches it once, deliberately, in a hand-written migration under `priv/legacy_migrations/`.

### The seed data is deliberately hostile

A clean seed proves nothing. `seed.sql` includes, on purpose:

- Two users whose emails differ only by case (`Dana@corp.example` and `dana@corp.example`). Our `identity :unique_email`
  on a `:ci_string` considers these the same user. The legacy index does not.
- A user with `email IS NULL` who signs in by `login`.
- A user whose `manager_id` points at a row with `deleted_at` set.
- Rows in `roles_users` referencing a `role_id` that no longer exists (the FK was added in 2018 with `NOT VALID` and
  never validated).
- `created_at` values in three different local time zones, because the app was moved between hosts twice.
- A `permissions` row with `subject_class = 'Invoice'` and `action = 'manage'`, which the legacy app treats as
  read+write+delete and which has no single equivalent in the eight-privilege Dataverse model.

Each of these has a defined resolution in the migration story, and each resolution is a decision someone has to make
rather than something the tooling can derive. That is the honest content of the demo.

## 4. Where it collides with the platform

This section is the reason the document exists. Everything below is a conflict between the legacy schema and
`AshEnterprise.Platform.Resource`, with the resolution and its cost.

### 4.1 Integer primary keys against uuid foreign keys

`lib/ash_enterprise/platform/transformers/add_system_attributes.ex` types `owner_id`, `created_by_id`,
`modified_by_id`, `owning_business_unit_id` and the rest as `:uuid`. A legacy-backed user with `id integer` cannot be
referenced by any of them.

Three options, and the plan takes two of them at different phases:

**Deterministic UUIDv5, computed in the view (read phase).**

```sql
-- One namespace UUID per legacy table, fixed forever, checked into the repo.
uuid_generate_v5('6b1e...'::uuid, 'legacy.users:' || u.id::text) AS id
```

`uuid_generate_v5` comes from `uuid-ossp`, which `AshEnterprise.Repo.installed_extensions/0` already installs.
Verified against PG 17.10: `pg_proc.provolatile = 'i'` — genuinely `IMMUTABLE`, unlike `uuid_generate_v4` (`'v'`) — so
the expression can be indexed, and it is:

```
CREATE INDEX users_v5_idx ON legacy.users
  (uuid_generate_v5('6b1e…'::uuid, 'legacy.users:' || id::text));

EXPLAIN SELECT * FROM strangler.users WHERE id = '8be4d3bf-…';
  Index Scan using users_v5_idx on users u
    Index Cond: (uuid_generate_v5('6b1e…'::uuid, ('legacy.users:'::text || (id)::text)) = '8be4d3bf-…'::uuid)
```

The same value is computable in Elixir, so application code and SQL agree without a lookup table, and there are zero
writes to the legacy schema. This is what makes phase 1 possible on a database you are not allowed to alter yet.

The cost is real: without that expression index, `WHERE id = $1` is a sequential scan, and the extension has to emit
the index automatically because nobody will remember to. And the reverse direction — given a UUID, find the integer —
is not computable at all. Hence the `legacy_id` column in the view, which every write trigger keys off.

**A stored `uuid` column on the legacy table (dual-write phase).** The first genuine expand step: add
`uuid uuid NOT NULL DEFAULT uuid_generate_v4()` — no, deliberately not; backfill it with the *same* v5 value so ids do
not change when the mechanism does, then index it. This is a write to a schema you do not own, and it is the moment the
migration stops being non-invasive. Say so out loud in the demo.

**A separate id-map table.** Rejected for this demo. It is the right answer when you cannot alter the legacy schema at
all, and it costs a join on every single read. Worth mentioning; not worth demonstrating.

> The subtlety that bites: `uuid_primary_key :id` generates a v4 UUID in Elixir on insert. A record created *through
> Ash* during the dual-write phase therefore gets a v4 id, while every record created by the legacy app gets a v5 id.
> Both are valid UUIDs and nothing breaks — but the invariant "id is derivable from the legacy id" now holds for some
> rows and not others, and any code that assumed it is wrong. The resolution is to make the legacy-backed resource
> declare its own `default` rather than use `uuid_primary_key`, and to have the `INSTEAD OF INSERT` trigger allocate
> the legacy `serial` and *recompute* the v5 id, discarding the one Ash sent. Which in turn means Ash's `RETURNING`
> must be trusted over the changeset — and `RETURNING` through an `INSTEAD OF` trigger is verified (extension plan
> §10.1) to report **whatever the trigger returned**, not what was stored. The obvious trigger body returns nulls for
> `id` and `created_at` and raises no error. This is the single most fragile mechanic in the design, and the demo
> should include the broken version first so the failure is visible before the fix is.

### 4.2 No tenant

`organization_id` is `allow_nil?: false` and drives attribute multitenancy on every platform resource. The legacy
application is single-tenant; there is no column to map.

The resolution is a constant in the view:

```sql
'00000000-0000-0000-0000-0000000000fe'::uuid AS organization_id  -- the "legacy" Organization
```

One `Organization` row is seeded to represent the entire legacy estate. Every legacy-derived record belongs to it.
This is correct and it is also the whole point: multitenancy is a property you can add to data that never had it,
precisely because the platform expresses tenancy as a column rather than as a database-per-customer deployment
decision. Had we chosen schema-based multitenancy, this step would be a database restructure instead of a literal in
a `SELECT`.

The honest cost: `global? true` is already set on our multitenancy config, so the queries work — but a tenant with
one member proves nothing about tenant isolation. The demo should therefore seed a *second*, greenfield Organization
alongside, and assert that the legacy tenant's rows are invisible from it. That assertion is the actual evidence.

### 4.3 No owning business unit

`RoleGrant` compares `owning_business_unit_id` against the actor's business-unit subtree. The legacy schema has
`company_id`, which was never a security boundary — it filtered reports.

Two-stage resolution:

1. **Phase 1 (read model):** every legacy row maps to the root business unit. Depth semantics degenerate — `:local`,
   `:deep` and `:global` all reach everything, and only `:basic` distinguishes anything. State this in the demo
   rather than hiding it, because it is what a real migration looks like on day one: **the authorization model is
   present but not yet load-bearing.**
2. **Phase 3 (backfill):** `legacy.companies` is projected into `BusinessUnit` rows preserving `parent_id` as the
   hierarchy, and `owning_business_unit_id` is backfilled from `company_id`. The moment that lands, depth starts
   discriminating, and *access narrows for everyone*. That is a production-affecting change disguised as a data
   backfill, and the demo should show the before/after `Ash.can?` matrix that makes it visible.

Step 2 is the single most valuable thing this demo proves, because it is the step every real migration gets wrong.

### 4.4 Ownership

`AshEnterprise.Accounts.User` is `ownership: :business_owned`, so it needs `owning_business_unit_id` and nothing else —
convenient. But every *other* legacy resource (invoices, purchase orders, whatever the demo grows) is `:user_owned`
and needs `owner_id`, `owner_type`, `owning_user_id`, `owning_team_id`.

`owner_id` maps to `uuid_generate_v5(ns, 'legacy.users:' || legacy_row.user_id::text)`; `owner_type` is the literal
`'user'`, because the legacy app has no concept of a team owning anything. `owning_team_id` is permanently NULL.

This is fine, and it is worth noticing *why* it is fine: the platform's ownership model is strictly richer than the
legacy one, so the mapping is a widening. Migrations only get hard when the legacy model is richer in some dimension —
which `legacy.permissions.action = 'manage'` is (§4.7).

### 4.5 Identities and case sensitivity

`identity :unique_email, [:email]` on an `attribute :email, :ci_string`. The legacy index on `email` is neither unique
nor case-insensitive, and the seed data contains a collision.

There is no clever resolution. This is a **data quality defect that the new model surfaces and the old model
tolerated**, and it must be resolved by a human before the read model can enforce the identity. The demo's job is to
make that discovery cheap:

- A `mix ash_enterprise.legacy.check` task that runs the identity's uniqueness assertion as a plain SQL query against
  the legacy tables *before* anything is built, and reports violations.
- The view initially declares the resource **without** the identity, so phase 1 works on dirty data.
- The identity is added, with the backing unique index, only at the expand step — and the migration that adds it fails
  loudly if the data still violates it.

Generalizing: **every Ash `identity` and every `allow_nil?: false` is an assertion about legacy data that is false
until proven.** The extension should be able to emit those assertions as a pre-flight check, and that is a concrete
feature requirement falling out of the demo rather than out of the design.

### 4.6 Passwords

`crypted_password` is `SHA1(salt + password)` in hex. `AshAuthentication`'s password strategy is configured with
`hash_provider AshAuthentication.BcryptProvider` and expects a bcrypt digest in `hashed_password`. SHA1 digests cannot
be converted to bcrypt — the plaintext is gone.

This is the hardest concrete problem in the demo, and it is hard in a way no DSL fixes.

Options, in the order a real team would consider them:

1. **Force a password reset for every user.** Correct, safe, and commercially unacceptable for anything above a few
   thousand accounts. Include it as the fallback and say why it is the fallback.
2. **Lazy rehash on successful sign-in.** The standard approach: verify against the legacy scheme, and on success,
   immediately hash the plaintext with bcrypt and write it. Users migrate transparently as they log in; after a
   defined window, force-reset the tail.

Option 2 requires work that `ash_authentication` does not currently make easy, and the demo should say so plainly:
the `password` strategy takes a single `hash_provider`, so supporting two schemes means writing a custom
`AshAuthentication.HashProvider` that dispatches on a discriminator prefix in the stored digest
(`"$legacy-sha1$<salt>$<hex>"` vs a standard `"$2b$..."`), plus a change on the sign-in action that rewrites the
digest on a successful legacy verification. That is maybe 80 lines, but it is 80 lines of security-critical code
written by hand, and it is *outside* what a schema-mapping extension can generate.

**Naming it is the deliverable.** A migration tool that generates views and triggers and then hands you the password
problem unsolved is still worth having — but only if it does not pretend otherwise.

Two further details the demo should not skip:

- `salt` and `crypted_password` are two columns mapping to one attribute. The `INSTEAD OF UPDATE` trigger must
  decompose `hashed_password` back into them during dual-write, or refuse to. Refusing is the right answer: mark the
  attribute non-writable through the legacy path and require that password changes go to the new table only. That
  makes password change the first action that *cannot* be dual-written, and therefore the first forcing function for
  cutover.
- `remember_token` / `activation_code` have no equivalent in our model at all; they are dropped, and dropping them
  logs out every legacy session at cutover. Schedule that, do not discover it.

### 4.7 Roles and permissions

Our security model is `(role, privilege, depth)` over eight privileges. The legacy model is
`(role, subject_class, action, scope)` over four verbs and three scopes, 94% of which are NULL.

The mapping is lossy in both directions:

| Legacy | Ours | Note |
|---|---|---|
| `action = 'read'` | `Read` | clean |
| `action = 'edit'` | `Write` | clean |
| `action = 'destroy'` | `Delete` | clean |
| `action = 'manage'` | `Read` + `Write` + `Delete` + `Assign` + `Share` | one row becomes five |
| `scope IS NULL` | `:global` | the honest reading of "unscoped", and it is a **widening** |
| `scope = 'own'` | `:basic` | clean |
| `scope = 'company'` | `:local` | clean, *conditional on §4.3 step 2 having happened* |
| — | `Append` / `AppendTo` | no legacy equivalent; must be granted by hand |

Two findings worth stating in the demo:

- `scope IS NULL → :global` is the widening that every migration of this shape contains. It is not a bug in the
  mapping; it is a faithful translation of an application that never restricted by row. The correct handling is to
  perform the translation, then run the conformance suite's truth table against the *migrated* grants and let a human
  look at what `:global` now reaches.
- The legacy `roles_users` table has no primary key, so it cannot be an Ash resource without an expand step
  (`ALTER TABLE legacy.roles_users ADD COLUMN id serial PRIMARY KEY`). It is therefore projected read-only through a
  view with a synthetic key (`uuid_generate_v5(ns, role_id || ':' || user_id)`) and never written through. Role
  assignment is one of the first write paths to cut over entirely, precisely because dual-writing it is awkward.

Unlike the password problem, this one *is* a good fit for the DSL: it is a pure declarative mapping with a lossy
expansion, and expressing it as data rather than as a one-off script is exactly the argument for the extension.

### 4.8 Audit, and the hole in it

`docs/adr/0002` and thesis 4 describe the audit log as covering every create, update and destroy on every resource.
During the dual-write phase, **that is false**, and the demo must be the thing that proves it rather than the thing
that hides it.

`AshEvents` writes an `audit_events` row as a side effect of an Ash action. The legacy Rails app does not call Ash
actions. Its writes go straight to `legacy.users` and produce no event.

Partial mitigation, and it is genuinely partial: an `AFTER INSERT OR UPDATE OR DELETE` trigger on the legacy table
fires `pg_notify`, the listener synthesizes an event, and the event lands in the log. What that event **cannot**
carry:

- **The actor.** Postgres knows the database role, which is `rails_app` for every legacy write. There is no user.
  `AshEnterprise.Platform.SystemActor` gains a `:legacy` member so these rows say `system_actor = "legacy"` rather
  than leaving `user_id` NULL, which is exactly the distinction that module exists to preserve — but "the legacy app
  did this" is not "Dana did this."
- **The correlation id.** No Ash transaction wrapped the write, so nothing groups the rows that changed together.
  `txid_current()` is available and is a reasonable substitute, and the demo should use it, with a note that it is a
  different identifier space from the application's correlation ids.
- **Delivery.** `pg_notify` is fire-and-forget. A listener that is down misses events permanently. An audit log with
  best-effort delivery is not an audit log.

The last point is decisive and the demo should draw the conclusion: **the notify path is good enough for cache
invalidation and LiveView reactivity, and not good enough for compliance.** If the audit log must be complete during
dual-write, the mechanism has to be a synchronous trigger that `INSERT`s into `audit_events` inside the legacy
transaction — with all the coupling and failure-mode cost that implies (a broken audit insert now rolls back the
legacy app's write). That is a genuine tradeoff between availability and completeness, it has no right answer, and
demonstrating the choice is worth more than demonstrating a mechanism.

### 4.9 Policies over a view

Policy filters become `WHERE` clauses, so the question is whether Postgres pushes them into the base table. Measured
against PG 17.10 (see the extension plan §10.6 for the full table): joins, `DISTINCT` and `GROUP BY` on the grouping
key all push down and use the base index. **Filters on computed columns do not** — they produce a `Seq Scan` with the
expression in `Filter`.

That is precisely the case here. `AshEnterprise.Security.Checks.RoleGrant` filters on `owning_business_unit_id`, which
in the phase-1 view is a *constant expression*, and would be a `CASE` over `company_id` after §4.3 step 2. So the
performance failure mode is not "views are slow" — it is specifically "**every column a policy filters on must be a
real column or have an expression index**."

It interacts with thesis 3's hard rule in an interesting way: the rule is that policy *checks* must not query, and they
do not. The problem is one level down, in the filters they produce. `ActorContext` correctly makes the check free; it
cannot make the resulting `WHERE` clause indexable.

The demo should include an `EXPLAIN`-based test asserting that a policy-filtered read of the legacy-backed user
resource does not sequentially scan `legacy.users`. Getting it to pass is the point of the expand step (§5, step 4).

### 4.10 Upserts, and whether AshAuthentication survives the view at all

Verified against PG 17.10 (extension plan §10.2): `INSERT … ON CONFLICT` does not work against a view. On a
single-table view it fails with *"there is no unique or exclusion constraint matching the ON CONFLICT specification"*;
on a joined view it fails earlier with *"cannot insert into view"*. And `ON CONFLICT DO NOTHING` does **not** swallow
the conflict — the base table's unique violation escapes from inside the trigger.

This lands directly on the demo, because the resource being migrated is `AshEnterprise.Accounts.User` and it carries
`extensions: [AshAuthentication]`. Several `ash_authentication` flows are upsert-shaped by nature — OAuth2/OIDC
sign-in creates-or-updates by identity, and confirmation add-ons update a record found by token.

Two consequences the demo has to confront rather than route around:

1. **The legacy-backed `User` cannot support the full authentication surface during `:read_from_legacy` and
   `:dual_write`.** It can support password sign-in (a read) and it can support reads generally. Registration and
   OAuth almost certainly need the new table. That makes authentication one of the *first* things to cut over, not one
   of the last — which inverts the usual instinct to migrate the scary thing last.
2. **Verification has to be at compile time**, because the runtime failure is a Postgrex error surfacing as a 500 in
   the middle of a sign-in flow. `VerifyNoUpserts` is the mechanism.

There is a second, subtler hazard the demo should show working: **a single-table view is automatically updatable even
with computed columns.** Verified — `UPDATE strangler.users SET email = …` succeeds with no `INSTEAD OF UPDATE`
trigger at all, `DELETE` likewise, and `MERGE` routes through the auto-update path even when an `INSTEAD OF INSERT`
trigger exists. So during `:dual_write`, a write can reach `legacy.users` by a path the mapping never described. The
demo should include exactly that: issue a `MERGE` against the view in `psql`, and show it landing in the base table
*without* incrementing the usage counter. That is the argument for generating all three triggers unconditionally, and
it is much more convincing demonstrated than asserted.

### 4.11 Archival, lifecycle, concurrency

The small ones, listed for completeness because each is a line of mapping and a decision:

| Platform | Legacy | Resolution |
|---|---|---|
| `archived_at` (AshArchival) | `deleted_at` | direct map; both are "soft deleted" |
| `state_code` / `status_code` | `state varchar` (`passive`/`pending`/`active`/`suspended`/`deleted`) | `CASE` in the view; reverse mapping needed for writes |
| `version_number` | — | no column. Optimistic locking is **off** for legacy-backed resources until the expand step adds one. State it; do not silently ship a resource whose concurrency control is a constant `1`. |
| `created_on` / `modified_on` (`utc_datetime_usec`) | `created_at` / `updated_at` (`timestamp`, local, three zones) | `AT TIME ZONE` per row range. Genuinely lossy; the demo should get one range wrong on purpose and show the reconciliation catching it. |
| `created_by_id` etc. | — | permanently NULL for legacy rows. Provenance for pre-migration data does not exist and cannot be manufactured. |

## 5. The migration story, step by step

Each step is a commit, each has an observable outcome, and each is reversible until step 6.

**Step 0 — Baseline.** `mix ash_enterprise.legacy.setup` creates and seeds `legacy.*`. A LiveView renders the legacy
`users` table by raw SQL, so there is something to watch. No Ash resources involved.

**Step 1 — Pre-flight.** `mix ash_enterprise.legacy.check` runs the assertions implied by the target resource:
uniqueness of `email` case-insensitively, non-nullness of every `allow_nil?: false` attribute, referential integrity of
`manager_id`. It fails, listing the seeded defects from §3. **This is the first deliverable and it should ship before
any view exists** — knowing whether the target model is even satisfiable is worth more than any amount of generated
DDL.

**Step 2 — Read model.** A view in schema `legacy_compat`, generated from the declarative mapping, plus
`AshEnterprise.Legacy.User` pointing at it with read actions only, no identity, and `migrate? false` on the legacy
tables. Outcome: the user list appears in `ash_admin`, in GraphQL, in JSON:API, and as an MCP tool — with no code
written for any of those surfaces. That is the derivation claim, tested against a schema nobody derived.

> Worth doing this step *twice*: once with `mix ash_postgres.gen.resources --tables --include-views`, which since
> ash_postgres 2.11 (May 2026) scaffolds read-only resources over existing views, and once with the strangler mapping.
> The comparison is the honest measure of what the extension adds over what the ecosystem already ships. If the
> difference is small at this phase — and it may well be — say so.

**Step 3 — Reactivity.** `AFTER` triggers on `legacy.users` emitting `pg_notify` with the legacy primary key; a
listener that re-reads through Ash and dispatches an `Ash.Notifier.Notification`. Outcome: edit a row in `psql`, watch
the LiveView update. This is the demo that sells the whole thing, and it is also the one whose delivery guarantees are
weakest — §4.8.

> The trigger-and-listen plumbing here should come from `ecto_watch` (1.1.0, actively maintained, ~108k downloads)
> rather than being written. What the demo adds on top is the Ash-specific bridge: re-reading through Ash so policies,
> tenancy and calculations apply, and synthesizing a real `Ash.Notifier.Notification` so LiveView cannot tell a legacy
> write from an Ash one. That bridge is a couple of hundred lines and it is the part worth showing.

**Step 4 — Expand.** The first and only migration that writes to the legacy schema: add `uuid`, `organization_id`,
`owning_business_unit_id`, `version_number` as nullable columns; backfill in batches; index concurrently. Legacy code
is untouched and unaware. Outcome: the view's computed columns become real columns, and the §4.9 performance problem
goes away for the ones that mattered.

**Step 5 — Backfill the security model.** `legacy.companies` → `BusinessUnit`; `legacy.roles` + `legacy.permissions` →
`Role` + `RolePrivilege` with the §4.7 mapping; `legacy.roles_users` → `UserRole`. Outcome: the conformance truth
table runs against migrated grants and access *narrows*. Diff the `Ash.can?` matrix before and after and put it in the
demo output. This is the step with the highest blast radius in any real migration.

**Step 6 — Dual write.** `INSTEAD OF INSERT/UPDATE/DELETE` on the view; Ash write actions enabled; a reconciliation
Oban job comparing row counts and checksums between the two shapes on a schedule; a usage counter incremented inside
the legacy-path triggers so there is *evidence* of when the legacy write path goes quiet. Password changes are
explicitly excluded (§4.6). Outcome: both applications write, in the same transactions, to the same rows.

**Step 7 — Cutover.** The new Ash-owned `users` table becomes the source of truth. The view is redefined to read from
it, so the legacy Rails app keeps working against `legacy.users`-as-a-view without a code change. Direction of the
`INSTEAD OF` triggers reverses. This is the highest-risk step and it is where a real migration would spend its
rollback plan.

**Step 8 — Decommission.** Drop the view, drop the triggers, drop the legacy tables. `AshEnterprise.Legacy.User`
becomes `AshEnterprise.Accounts.User` — the identical module we ship today, with no strangler DSL in it at all.

That last property is the acceptance criterion for the whole design: **the end state must be a resource that shows no
evidence the migration happened.** If the extension leaves residue in the resource file, it is a framework, not a
migration tool.

## 6. What this proves that a greenfield app cannot

Five things, in descending order of how much they are worth.

1. **That the platform's assumptions are separable from its value.** `AshEnterprise.Platform.Resource` bundles a dozen
   concerns. A greenfield app cannot tell you whether they are a coherent set or an accidental one, because it never
   has to take any of them apart. A legacy migration takes them apart one at a time and reports which ones were load
   bearing. If it turns out you cannot have the audit log without `uuid` primary keys, that is a design defect in this
   repository, and it is only discoverable this way.

2. **That authorization-as-data can be retrofitted.** Thesis 3 argues that `(role, privilege, depth)` rows beat
   `if user.admin?`. Every application that would benefit from that argument already has the `if` statements. The
   demonstration that matters is not "here is a clean model" but "here is that model, derived from an existing mess,
   with the widenings and losses enumerated" — §4.7 and step 5.

3. **That derivation survives an undesigned schema.** Every API surface, admin screen, diagram, and LLM tool in this
   repository is derived from resources we wrote. Pointing the same machinery at a view over a 2010 Rails schema is a
   real test of whether the derivation is general or whether it only works on schemas shaped like its own output.

4. **What a complete audit trail actually costs.** §4.8 is not a limitation of the extension; it is a property of the
   world. You cannot audit writers you do not control without either coupling their transactions to your log or
   accepting an incomplete log. A greenfield app never confronts this because it controls every writer, which is
   exactly why greenfield audit claims are cheap.

5. **That the migration ends.** Most strangler-fig case studies stop mid-strangle; the cited industry figure is that
   most stall before completion. A reference app that runs all eight steps to a resource with zero migration residue
   is a claim about completability, and it is the only one of the five that requires actually finishing.

## 7. What this does not prove

- **Scale.** A seeded schema of a few thousand rows says nothing about backfilling 40 million, where lock duration,
  index build time and replication lag dominate every decision here.
- **Concurrent legacy load.** The demo's "legacy application" is `psql` and a seed script. Real dual-write failures
  come from a live application with connection pools, its own transaction boundaries, and its own retry logic.
- **That the mapping DSL is expressive enough.** One schema, chosen by us, mapped to a model we also chose. The demo
  can only show the DSL handles the case it was designed against. Expressiveness is proven by a second, unrelated
  legacy schema — which is the obvious next thing and is explicitly not in this plan.

## 8. Ordering and prerequisites

This work is DEFERRED. It requires, in order:

1. Organization and tenancy complete — §4.2 has nothing to map to otherwise.
2. Hierarchy security complete — the §4.3 backfill changes what hierarchy grants reach, and testing that before
   hierarchy exists tests nothing.
3. The extension itself, at least through its read-model phase ([`ash-strangler.md`](ash-strangler.md)).

Steps 0 and 1 of §5 are the exception: the legacy schema and the pre-flight checker have no dependency on the
extension and could be built at any point. They are also where most of the learning is. If only one piece of this
document is ever built, build those two.
