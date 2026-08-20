# Plan — AshStrangler in the reference application

- **Status:** **PARTIALLY BUILT.** Steps 0, 2 and 3 of [§5](#5-the-migration-story-step-by-step) have landed — the
  simulated legacy schema, the read model over it, and the reactivity bridge that makes a legacy write visible in a
  LiveView. Steps 1 and 4 onward are not built. The parts that *are* built are marked below.

  The original deferral said to wait for Organization and tenancy (Phase 5) and hierarchy security (Phase 6), which is
  what steps 2 and 3 turned out to need and now have. Steps 5 through 8 still depend on work that does not exist, and
  step 5 in particular (`legacy.companies` → `BusinessUnit`) narrows access for everyone the moment it lands, so it is
  not something to slip in.
- **Date:** 2026-08-13, revised 2026-08-19
- **Depends on:** [`ash-strangler.md`](ash-strangler.md), at least through its read-model phase. Two steps
  ([§5](#5-the-migration-story-step-by-step), steps 0 and 1) do not.
- **Mapping decisions** follow [ADR 0008](../adr/0008-typed-invertible-legacy-mappings.md): every mapping is a typed
  expression whose inverse is proven, not asserted. §4.1, §4.2, §4.6, §4.7 and §4.11 are written that way.

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

**One line of mapping decides whether upserts still work.** A view is auto-updatable — upserts included — until an
`INSTEAD OF` trigger appears, and whether the mapping needs one is decided column by column. `AshAuthentication` needs
upserts. Verified, §4.10. This is a constraint on how each column is mapped, and it is invisible until you try it.

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

```elixir
# The declaration. The namespace is fixed forever and checked into the repo, and
# it lives on the migration group -- once, rather than on each of the resources
# sharing legacy.users.
key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e..."}
```

```sql
-- What it generates in the view's SELECT list.
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

```elixir
# The "legacy" Organization -- one row representing the whole legacy estate.
constant :organization_id, expr(type("00000000-0000-0000-0000-0000000000fe", :uuid))
```

```sql
'00000000-0000-0000-0000-0000000000fe'::uuid AS organization_id
```

It is also the literal the backfill needs, and it is not retyped there: `AshStrangler.Backfill.plan/2`
reads the `constant` entities directly, so nobody restates it as a raw SQL string in
`set: [organization_id: "'0000…fe'::uuid"]`. The literal is declared once and the two places that need it
— the view's `SELECT` list and the backfill's `UPDATE` — are both derived from that one declaration.

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

  The refusal is written as an explicit opt-out, and the distinction matters:

  ```elixir
  map :hashed_password,
    from: expr("$legacy-sha1$" <> salt <> "$" <> crypted_password),
    writable?: false,
    because: "Password changes must not be written back into a SHA1 scheme. Cut over first."
  ```

  Note that `concat` with a literal separator *is* in the invertible tier — `$` is provably absent from a
  40-character hex digest and from the salt, so the tool can derive the decomposition. Refusing here is
  therefore a **policy** decision rather than a limit of the grammar, and `writable? false` with a
  `because` says so out loud. That is the case the opt-out exists for, and the demo should draw the
  distinction: a mapping that *cannot* travel back is a fact about the expression, a mapping that *must
  not* is a judgement somebody made, and only the second one needs a sentence of prose attached to it.
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

It is two combinators, and each carries its own proof obligation:

```elixir
# scope -> depth. A bijection over the three legacy values, so `decode` derives
# both directions and checks exhaustiveness against the depth enum. The widening
# is visible in the declaration rather than buried in a CASE.
decode :depth, from: :scope, %{
  nil        => :global,   # the honest reading of "unscoped" -- and a WIDENING
  "own"      => :basic,
  "company"  => :local     # correct only once §4.3 step 2 has happened
}

# action -> privileges. One legacy row becomes up to five, so this is NOT a
# bijection and `collapse` is the wrong shape: the forward direction fans out.
# It is declared as an expansion with an explicit inverse policy.
expand :privileges, from: :action, %{
  "read"    => [:read],
  "edit"    => [:write],
  "destroy" => [:delete],
  "manage"  => [:read, :write, :delete, :assign, :share]
} do
  # `manage` is the only many-valued row, so the inverse is only defined on
  # exactly that set. Anything else -- notably any grant including :append or
  # :append_to, which have no legacy equivalent -- cannot travel back.
  writable? false
  because "Ours is strictly richer: :append/:append_to have no legacy verb, and a partial subset of \
           `manage` has no legacy encoding. Grant those in the new model only."
end
```

Two things this buys that a script does not. The `:global` widening is now a **declared** entry rather
than an implicit `ELSE`, so it appears in the mapping diagram as its own edge and a reviewer is asked to
look at it — which §4.7 already argues is the correct handling. And `PutTotal` refuses the mapping if the
`Privilege` enum grows a value with no legacy encoding and nobody updated the table, which is exactly how
this kind of mapping rots.

The `roles_users` case is unchanged and still needs a synthetic key
(`key :id, strategy: {:uuid_v5, ...}` over `role_id || ':' || user_id`), still read-only, still one of
the first write paths to cut over entirely.

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

### 4.10 The trigger trade, and whether AshAuthentication survives the view

This is the conflict that most changes how the demo has to be built, and it is not a conflict with our platform — it
is a conflict inside Postgres.

Verified against PG 17.10 (extension plan §10.2). A **single-table view with computed columns is automatically
updatable**: `UPDATE strangler.users SET email = …` succeeds with no `INSTEAD OF UPDATE` trigger, `DELETE` likewise,
`MERGE` likewise, and `INSERT … ON CONFLICT (email) DO UPDATE … RETURNING …` **works**, resolving through to the base
table's unique index. Adding an `INSTEAD OF` trigger to that same view silently removes all of it: upserts break,
`RETURNING` starts reporting whatever the trigger returned, and `WITH CHECK OPTION` is ignored without a warning.

So the demo has two mutually exclusive modes and must show both.

**Without triggers**, `AshEnterprise.Accounts.User` keeps its full `AshAuthentication` surface — which matters,
because several flows are upsert-shaped by nature (OAuth2/OIDC sign-in creates-or-updates by identity). But writes can
reach `legacy.users` by a path the mapping never described. The demo should prove it: issue a `MERGE` against the view
in `psql` and show it landing in the base table, un-mapped and uncounted.

**With triggers**, every write is governed and the usage counter (§5, step 6) exists at all — but upserts are gone,
and the failure is a Postgrex error surfacing as a 500 mid-sign-in unless a compile-time verifier catches it first.

Neither mode is correct in general. What the demo proves is that **the choice is forced by the mapping, not by
preference — and it is forced one column at a time**, which is the finer and more interesting result.

`CREATE VIEW`'s updatability rule is column-level: a view mixing plain and computed columns is automatically
updatable, and a computed column raises an error only if a statement *assigns* it. Measured on PostgreSQL 17.10, such
a view kept `UPDATE` of its plain columns, `DELETE`, and `INSERT … ON CONFLICT … RETURNING` — including on the run
where the conflict actually fired — with **no triggers at all**. Upserts are lost to the trigger, not to the
computation.

So the question to ask of each mapping is not "is this column computed?" but "does any write path have to assign it?"
Our `full_name` mapping is read-only and costs nothing. A `decode`d `state_code` that the new model writes is a
candidate for a `GENERATED … STORED` column or a `BEFORE` trigger on `legacy.users` — push the computation down to the
base table and the compatibility view stays auto-updatable, so `AshAuthentication` keeps its full surface and
authentication does not have to lead the migration. Reach for `INSTEAD OF` and you have bought the trigger mode for
every column on the resource at once, for the sake of one of them.

The `MERGE`-bypasses-the-mapping demonstration stands either way: an auto-updatable view really can be written by a
path the mapping never described, and that is the honest cost of *not* using triggers.

> One further measured hazard for whichever mode the demo runs: under an `INSTEAD OF` trigger,
> `WITH CHECK OPTION` is not merely unenforced. The same violating `INSERT` that the plain
> auto-updatable view **refuses** succeeds, and the row lands in `legacy.users`. If the view carries a
> tenant or soft-delete predicate — and §4.2 means it will — the predicate must be re-implemented as an
> explicit guard inside the trigger body. This is one of the consequences recorded in
> [ADR 0008](../adr/0008-typed-invertible-legacy-mappings.md).

### 4.11 Archival, lifecycle, concurrency

The small ones, listed for completeness because each is a line of mapping and a decision:

| Platform | Legacy | Resolution |
|---|---|---|
| `archived_at` (AshArchival) | `deleted_at` | direct map; both are "soft deleted" |
| `state_code` / `status_code` | `state varchar` (`passive`/`pending`/`active`/`suspended`/`deleted`) | **`decode`** — one declared bijection, both directions derived from a single map. See the note below: this is the mapping where a wrong inverse rewrites lifecycle states silently |
| `version_number` | — | no column. Optimistic locking is **off** for legacy-backed resources until the expand step adds one. State it; do not silently ship a resource whose concurrency control is a constant `1`. |
| `created_on` / `modified_on` (`utc_datetime_usec`) | `created_at` / `updated_at` (`timestamp`, local, three zones) | `AT TIME ZONE` per row range. Genuinely lossy; the demo should get one range wrong on purpose and show the reconciliation catching it. |
| `created_by_id` etc. | — | permanently NULL for legacy rows. Provenance for pre-migration data does not exist and cannot be manufactured. |

> **Why `state` is a `decode`, and what `decode` proves about it.** Legacy `state` ranges over
> `passive | pending | active | suspended | deleted`; `state_code` is a small integer. Map the two
> directions as two independent expressions and nothing relates them: `from "CASE state WHEN 'active'
> THEN 0 ELSE 1 END"` paired with `to "CASE $NEW.state_code WHEN 0 THEN 'active' ELSE 'suspended' END"`
> is a bijection on `{active, suspended}` and destroys the other three states. Measured on
> PostgreSQL 17.10, one `UPDATE` through such a view assigning **only the email** rewrote `passive`,
> `pending` and `deleted` to `suspended` — no error, correct row count, five lifecycle states collapsed
> to two. Declared as a `decode`, both directions come from one map, and the round trip is checked at
> compile time over the *legacy* value space — every value `state` actually takes, not the ones the
> author happened to think of. See [ADR 0008](../adr/0008-typed-invertible-legacy-mappings.md), and
> `documentation/topics/the-transform-layer.md` in the `ash_strangler` repository for how the tiers are
> decided.
>
> The demo should show the failure before the mapping that refuses it — exactly the shape §4.1
> recommends for the `RETURNING` hazard: **include the broken version first, so the failure is visible
> before the fix is.** It is the single most persuasive thing this demo can show, because there is
> nothing to see when it goes wrong: no exception, no rollback, and a row count that matches what the
> operator expected.

## 5. The migration story, step by step

Each step is a commit, each has an observable outcome, and each is reversible until step 6.

**Step 0 — Baseline. ✅ BUILT.** `mix ash_enterprise.legacy.setup` creates and seeds `legacy.*`. A LiveView renders the legacy
`users` table by raw SQL, so there is something to watch. No Ash resources involved.

**Step 1 — Pre-flight. ❌ NOT BUILT.** `mix ash_enterprise.legacy.check` runs the assertions implied by the target resource:
uniqueness of `email` case-insensitively, non-nullness of every `allow_nil?: false` attribute, referential integrity of
`manager_id`. It fails, listing the seeded defects from §3. **This is the first deliverable and it should ship before
any view exists** — knowing whether the target model is even satisfiable is worth more than any amount of generated
DDL.

> `mix ash_strangler.check` runs exactly these assertions against the legacy data, alongside the mapping
> report and the join fan-out measurement. What makes that nearly free is the *twin*:
> `mix ash_strangler.gen.twin` turns the legacy relation into a real Ash resource, so each assertion is a
> query the target model already implies rather than SQL anybody writes:
>
> | Model assertion | The check it becomes |
> |---|---|
> | `allow_nil? false` | `Ash.count(twin, filter: is_nil(^source))` |
> | `identity :unique_email` on a `:ci_string` | an aggregate grouped by the normalised expression |
> | a cast, or a `decode` table | project the mapping over the twin and count the failures |
> | `manager_id` referential integrity | an `exists` filter across the twin's own relationship |
>
> That decides who owns which half rather than whether the step is worth doing. Written through the twin,
> the assertions belong to the extension and this repository's task is a thin wrapper naming the resources
> and the mapping. Written standalone it needs nothing but `psql`, which is why §8 can list step 1 as
> having no dependency on the extension at all.

**Step 2 — Read model. ✅ BUILT.** A view in schema `strangler` (not `legacy_compat` — the extension names the schema
after itself, and there was no reason to fight it), generated from the declarative mapping, plus
`AshEnterprise.Legacy.User` pointing at it with read actions only, no identity, and `migrate? false` on the legacy
tables. Outcome: the user list appears in `ash_admin`, in GraphQL, in JSON:API, and as an MCP tool — with no code
written for any of those surfaces. That is the derivation claim, tested against a schema nobody derived.

> Worth doing this step *twice*: once with `mix ash_postgres.gen.resources --tables --include-views`, which since
> ash_postgres 2.11 (May 2026) scaffolds read-only resources over existing views, and once with the strangler mapping.
> The comparison is the honest measure of what the extension adds over what the ecosystem already ships. If the
> difference is small at this phase — and it may well be — say so.

**Step 3 — Reactivity. ✅ BUILT.** `AFTER` triggers on `legacy.users` emitting `pg_notify` with the legacy primary
key; a listener that re-reads through Ash and dispatches an `Ash.Notifier.Notification`. Outcome: edit a row in `psql`,
watch the LiveView update. This is the demo that sells the whole thing, and it is also the one whose delivery guarantees are
weakest — §4.8.

> The trigger-and-listen plumbing here should come from `ecto_watch` (1.1.0, actively maintained, ~108k downloads)
> rather than being written. What the demo adds on top is the Ash-specific bridge: re-reading through Ash so policies,
> tenancy and calculations apply, and synthesizing a real `Ash.Notifier.Notification` so LiveView cannot tell a legacy
> write from an Ash one. That bridge is a couple of hundred lines and it is the part worth showing.

**Step 4 — Expand. ❌ NOT BUILT.** The first and only migration that writes to the legacy schema: add `uuid`, `organization_id`,
`owning_business_unit_id`, `version_number` as nullable columns; backfill in batches; index concurrently. Legacy code
is untouched and unaware. Outcome: the view's computed columns become real columns, and the §4.9 performance problem
goes away for the ones that mattered.

**Step 5 — Backfill the security model. ❌ NOT BUILT.** `legacy.companies` → `BusinessUnit`; `legacy.roles` + `legacy.permissions` →
`Role` + `RolePrivilege` with the §4.7 mapping; `legacy.roles_users` → `UserRole`. Outcome: the conformance truth
table runs against migrated grants and access *narrows*. Diff the `Ash.can?` matrix before and after and put it in the
demo output. This is the step with the highest blast radius in any real migration.

**Step 6 — Dual write. ❌ NOT BUILT.** `INSTEAD OF INSERT/UPDATE/DELETE` on the view *if the mapping forces them* (§4.10) — and the
demo should run this step twice, once each way, because the difference is the whole lesson; Ash write actions enabled; a reconciliation
Oban job comparing row counts and checksums between the two shapes on a schedule; a usage counter incremented inside
the legacy-path triggers so there is *evidence* of when the legacy write path goes quiet. Password changes are
explicitly excluded (§4.6). Outcome: both applications write, in the same transactions, to the same rows.

**Step 7 — Cutover. ❌ NOT BUILT.** The new Ash-owned `users` table becomes the source of truth. The view is redefined to read from
it, so the legacy Rails app keeps working against `legacy.users`-as-a-view without a code change. Direction of the
`INSTEAD OF` triggers reverses. This is the highest-risk step and it is where a real migration would spend its
rollback plan.

**Step 8 — Decommission. ❌ NOT BUILT.** Drop the view, drop the triggers, drop the legacy tables. `AshEnterprise.Legacy.User`
becomes `AshEnterprise.Accounts.User` — the identical module we ship today, with no strangler DSL in it at all.

That last property is the acceptance criterion for the whole design: **the end state must be a resource that shows no
evidence the migration happened.** If the extension leaves residue in the resource file, it is a framework, not a
migration tool.

## Visual cue

Step 3's outcome is "watch the LiveView update", and a table that quietly gains a row is a poor demonstration of that:
by the time you look back at the screen, nothing distinguishes the new state from the state you were already looking
at. So the surface raises a cue. What follows is where the boundary between what works and what does not actually
falls, because it is not where you would guess.

### What was built

A banner above the surface, keyed on a counter, that fades in on `phx-mounted` and clears itself after six seconds.
Every part of that is ordinary LiveView, because the banner is **LiveView's own DOM**:

```elixir
<div :if={@cue} id={"legacy-cue-#{@cue}"}>
  <div phx-mounted={JS.transition({"transition-all duration-500 ease-out",
                                   "opacity-0 -translate-y-1",
                                   "opacity-100 translate-y-0"}, time: 500)}>
```

Two details are load-bearing. The element is **keyed on the counter**, so a second change removes and re-adds it — and
`phx-mounted` fires on being added, so without the key only the first change would ever animate. And the cue is raised
on the renderer's internal `{:ash_a2ui, :refresh}` message rather than on the PubSub broadcast, because the renderer
debounces 150 ms: announcing an update before the rows arrive reads as a bug even though nothing is wrong.

### Why the changed *row* is not highlighted

This is the interesting half. The canonical LiveView techniques for "flash the thing that changed" are well documented
and there are three of them. **None of them reach a row on an A2UI surface**, and it is the same reason each time.

The renderer's container is `<div id="ash-a2ui-surface" phx-hook="AshA2ui" phx-update="ignore">`, and the components
inside it are custom elements rendering into **shadow DOM**. So LiveView does not render the rows, does not patch them,
and cannot see them:

| Technique | Why it does not apply here |
|---|---|
| `push_event` + `liveSocket.execJS(el, el.getAttribute("data-highlight"))` | Needs an element carrying a `data-*` JS command that LiveView rendered. LiveView renders no rows here, and `document.querySelectorAll` does not cross a shadow boundary. |
| `phx-mounted={@fresh && JS.transition(...)}` on a stream item | Needs LiveView to render the element. Same reason. There is no stream: the surface is one pushed `updateDataModel` message. |
| A CSS keyframe that restarts when a node is inserted | Needs the rule to exist *inside* the shadow root. App stylesheets do not cross the boundary. Only inherited custom properties (`--a2ui-*`) do. |

The pattern is worth stating plainly because it generalises past this one page: **`phx-update="ignore"` plus shadow DOM
means the host application's cue vocabulary stops at the container.** Anything richer has to come from inside.

### The three ways a row-level highlight could actually happen

**Make the cue data, not decoration.** The surface already renders `row_layout`'s `badge` from a field. A calculation
like `expr(modified_on > ago(30, :second))` would badge the recently-changed rows with no JavaScript at all, and it
would survive the full data-model replacement because it *is* part of the data model. The catch is that it cannot clear
itself: the badge disappears on the next refresh, and the next refresh only comes from the next write. Good enough to
demonstrate, dishonest as a general mechanism.

**Diff in the hook.** `priv/js/ash_a2ui_hook.js` receives every `updateDataModel` and could compare the incoming rows
against the previous ones by key, then set an attribute on the changed rows *inside* the shadow root — where a
`--a2ui-*`-themed animation can reach them. This is the correct fix and it belongs upstream in `ash_a2ui`, not here: it
is a property of the renderer, every surface wants it, and it is the only one of the three that knows *which* rows
changed rather than guessing from a timestamp.

**Send the changed keys with the refresh.** The notification already carries `legacy_id` and the derived `id`, and the
LiveView already knows them at refresh time. Pushing them alongside the data model would let the hook highlight exactly
the rows the database said changed rather than diffing for them. Cheaper and more precise than diffing, but it needs a
protocol addition, so it is the option that should be argued for rather than assumed.

Until one of those exists, the banner is the honest cue: it tells you the table was rebuilt, and it does not pretend to
know more than it does.

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

---

# Addendum — 2026-08-20: step 3½, the projection

**Appended, not merged.** Per the convention in [`README.md`](README.md), nothing above this line has
been edited. This section records something that was built which the plan above does not contain: it
sits between [step 3](#5-the-migration-story-step-by-step) and step 4, it is not one of the eight
steps, and it should not be counted as progress along them. The decision and its alternatives are
[ADR 0031](../adr/0031-the-legacy-estate-is-projected-not-cut-over.md); this is the plan-shaped record
of what it changes about §5 and `## Visual cue`.

## What was asked for, and which step it turned out to be

A UI generated for the **new** schema, receiving the inserts made into the **legacy** table, updating
**live**. The third clause was step 3 and already worked. The first clause — a table this application
owns, rather than a view whose columns are a `SELECT` list — is **step 7, Cutover**.

**Step 7 was rejected, and the mapping is what rejected it.** At `:read_from_new` the legacy name
becomes a view over the new table with `INSTEAD OF` triggers, so every mapping has to run backwards, and
`AshStrangler.Verifiers.VerifyReverseMappable` refuses the phase over anything classified
`invertible: :no` or `:semi`. `AshEnterprise.Legacy.User` has three: `full_name`, `legacy_state` and
`lifecycle_status`, each carrying the mandatory `because:` that makes it one.

**One of those three is a place the plan above was wrong, and it is worth naming rather than glossing.**
[§4.11](#411-archival-lifecycle-concurrency) predicts legacy `state` will be a **`decode`** — *"one
declared bijection, both directions derived from a single map"* — onto `state_code`/`status_code`. What
shipped is not a bijection and does not touch `state_code`: `legacy_state` carries the legacy value
verbatim and `lifecycle_status` is a lossy `if(state == :active, …)` collapse, both `read_only?`, because
the platform's `lifecycle_status` has **two** values and no `decode` can be a bijection onto five. §4.11's
own warning about wrong inverses rewriting lifecycle states silently is correct and was heeded; its
proposed *mechanism* assumed a target enum wide enough to hold the source, and this one is not. The
consequence is that one of the three mappings blocking `:read_from_new` was predicted to be the mapping
that made the phase *safe*.

The verifier's remedy is *"carry those legacy columns across unchanged as
well"*, which means the new table holds `first_name`, `last_name` and `state` rather than deriving them
— and a target resource that carries the legacy columns is not the resource §5's step 8 acceptance
criterion describes. Steps 4, 5 and 6 are also in the way, and step 5 is the one this plan calls **the
step with the highest blast radius in any real migration**.

So the direction was inverted instead. Data flows legacy → new and only that way — the direction the
mapping is already proven in, where no inverse is needed and the one-way door stays shut.

## What was built

**Step 3½ — Projection. ✅ BUILT.** `AshEnterprise.Accounts.ProjectedUser` over `projected_users`, an
Ash-owned table created by `mix ash.codegen`, kept current by `AshEnterprise.Legacy.Projection` — a
second `Ash.Notifier` on `Legacy.User`, consuming the notification `AshStrangler.Listener` already
dispatches. `mix ash_enterprise.legacy.project` establishes the starting state, because the projector
reacts to *changes* and a fifteen-year-old row has never produced one.
`AshEnterpriseWeb.A2ui.ProjectedUserUI` renders it at `/app/directory`, live, beside
`/app/legacy-users`. Outcome: **the same nine people over a view and over a table, both updating from a
`psql` INSERT, side by side.**

Three things fall out of it that no step above delivers:

- **The write is audited.** §4.8's hole is a property of the world — you cannot audit writers you do not
  control — and it stays open for the legacy application's writes. But the *projection's* write is an
  ordinary Ash action, so it produces an ordinary hash-chained audit event, attributed to
  `SystemActor.projection/0` rather than to a person. §6.4 says a greenfield application never confronts
  this; the projection is the first place in this exercise where the honest answer improves.
- **The five-onto-two collapse becomes a transition.** `lifecycle_status` is reached by running the
  platform's own `:deactivate` action, not by writing the attribute — `initial_states [:active]` forbids
  creating a row already inactive, correctly. On the read model the collapse is a derivation computed on
  every `SELECT` and recorded nowhere; here an auditor can find the transition that produced it.
- **Nothing on the projected surface is strangler-aware.** The two `use AshA2ui.LiveRenderer` blocks are
  the same options over a different UI module. `/app/directory` subscribes to `projected_users:*` because
  the resource declares those publications, and cannot tell a projected write from a create made by a
  person in the admin UI.

`AshStrangler.Backfill` is deliberately *not* used for the backfill: it fills columns **within** a legacy
table, which is step 4. This copies rows **out** of one, and the estate is nine users. At a million it
would need to stream and commit per batch, and the task's moduledoc says so rather than pretending
otherwise.

## What it does not change

It is **not** progress along §5. The phase is still `:read_from_legacy`, the legacy database is still the
system of record, `projected_users` is derived, and the three `read_only?` mappings are still not
invertible. Step 7 costs exactly what it cost before. One piece of it is now established early:
`ProjectedUser` stores `legacy_id`, which `ash_strangler`'s usage rule 21 requires *before* cutover
because the uuid derivation runs one way and a reverse view cannot recover the integer key.

Two of §7's three disclaimers apply unchanged and one gains a new instance. **Scale**: a projection over
nine rows says nothing about projecting forty million, where the absence of batching stops being an
honest simplification. **Concurrent legacy load**: the "legacy application" is still `psql`.
**Expressiveness**: unchanged — one schema, chosen by us.

And the reliability story is weaker than the read model's in one specific way. A row that fails to
project is **silently absent** from `projected_users` until something re-runs the backfill: there is no
retry and no dead-letter queue, because containment has to live in the notifier — a notifier that raises
takes the listener's process with it, and the listener holds the only `LISTEN` connection, so one bad row
would stop reactivity on *every* surface including the read model's. The reconciliation job that would
close that gap is **step 6**, and this is not it.

## What `## Visual cue` gets right, and the one thing it now understates

Everything in that section holds. `AshEnterpriseWeb.A2uiLive.Cue` was extracted when the second live
surface arrived, and the three load-bearing properties it names are exactly the three that would have
drifted between two copies: the element is keyed on the counter (`phx-mounted` fires on insertion, so
without the key it animates once and never again), the counter is bumped on the renderer's debounced
`{:ash_a2ui, :refresh}` rather than on the broadcast, and the timer is cancelled and replaced rather than
accumulated. Both surfaces call it with a different `id_prefix` and a different message, so two banners
on one page cannot collide.

**What the section understates is the first of its three routes to a row-level highlight.** *"Make the
cue data, not decoration"* is dismissed as *"good enough to demonstrate, dishonest as a general
mechanism"*, on the grounds that a badge cannot clear itself. On the projected table that objection is
softer, because `projected_at` exists as a real column — it is on screen precisely so the lag is a number
rather than a hope — and a calculation over it needs no `modified_on` heuristic. It still cannot clear
itself without a write, so the conclusion does not change. But the reasoning behind it is now weaker
than the text implies, and the note about where the badge must come from is a hard constraint worth
repeating: `row_layout`'s `badge` must name one of the table's own fields, and `AshA2ui`'s layout
verifier refuses otherwise — which is how a draft of `ProjectedUserUI`'s moduledoc was caught claiming a
column had been dropped.

The other two routes are unaffected. Diffing in `priv/js/ash_a2ui_hook.js` is still the correct fix and
still belongs upstream; sending the changed keys with the refresh is still cheaper, more precise, and
still needs a protocol addition.

## Three findings, all from running it rather than reading it

Recorded here because §5's steps were written as forecasts and this section is a record, and because
`README.md` says the gap between the two is the point.

**The backfill and the live projector disagreed.** The task rebuilt the attribute map itself and called
the upsert directly, skipping the lifecycle transition — so a legacy user in `suspended` or `passive` sat
in `projected_users` marked `:active`, and whether a row was right depended on whether anyone had edited
it since the projector started. Found by one `SELECT`, not by reading the code. Fixed by making
`Projection.project_row/1` the only entry point; a test now pins three logins across both states.

**An ordering trap that points both ways, which §3 half-anticipated and §5 does not mention.**
`mix ash_enterprise.legacy.setup` must run **before** the migrations, because the strangler view needs
`legacy.users` to exist. The projection must run **after** them, because `projected_users` is Ash-owned.
Wiring the projection into `legacy.setup` — where it looks like it belongs, beside the rest of the legacy
plumbing — produced nine `relation "projected_users" does not exist` errors on a fresh database, each
reported as a *refused row*. One refusal is a data-quality finding worth printing; nine refusals for the
same structural reason is a mistake wearing a finding's clothes. It is now sequenced after `ash.setup` in
`setup` and `ecto.setup`, with an `ensure_table!/0` guard in the task that raises and explains both
directions. The `test` alias deliberately does not project, because every test that cares seeds the
estate inside its own sandbox transaction.

**A new resource is invisible until the privilege catalogue is regenerated.** `/app/directory` rendered
zero rows with the whole chain working: `privileges` held nothing for
`AshEnterprise.Accounts.ProjectedUser`, so the Administrator role granted nothing over it.
`Seeder.regrant_administrator_privileges/1` returned 0, because it only grants privileges that *exist* —
`seed_privileges/0` has to run first. Measured on a fresh database: 248 written, then 8 regranted per
tenant, one per `AccessRight` verb. This is a standing consequence of deriving the catalogue from the
resources that exist at seed time, and its failure mode presents as a broken feature rather than as a
stale grant.

## The tenant confusion, which is §4.2 working correctly

Not a finding about the projection, and worth writing down because it will cost somebody an afternoon.
`/app/legacy-users` and `/app/directory` both show **nothing** to `admin@example.com`. The legacy rows
belong to the `legacy` organization — §4.2's one `Organization` row representing the whole estate — and
both surfaces are tenant-scoped like every other resource here. The demo has to sign in as
`admin@legacy.example`.

That is correct, and it is confusing, because an empty table looks exactly like a broken feature.
`scripts/screenshots/capture-live.mjs` therefore defaults `EMAIL` to `admin@legacy.example` with a
comment saying why, and distinguishes *"projected_users is empty — run `mix ash_enterprise.legacy.project`
first"* from *"reached `legacy.users` but never reached `projected_users`"* in its failure list, so a
capture cannot pass by photographing an empty page. The INSERT is made by `psql` and not through the
application, deliberately: a demo where the application writes its own row and then notices it proves
nothing.
