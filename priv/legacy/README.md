# The simulated legacy schema

`legacy.*` is a 2010-era Rails 2.3 application's schema: `restful_authentication`
for identity, an `acl9`-shaped role table, and a `permissions` table someone
bolted on in 2013. It exists so the strangler-fig migration in
[`docs/plans/ash-strangler-in-reference-app.md`](../../docs/plans/ash-strangler-in-reference-app.md)
has something real to strangle.

```bash
devenv shell -- mix ash_enterprise.legacy.setup
```

## Ash must not touch these tables

This is the hard rule, and it is what makes the demonstration honest rather than
circular:

- **`schema.sql` is applied with `psql`, not as an Ecto migration.** The moment
  `legacy.*` appears in `priv/repo/migrations`, the demo is lying about the
  situation it demonstrates — a schema this application does not own.
- **Every resource reading these tables declares `migrate? false`.** Ash owns
  the compatibility view in schema `strangler`; it does not own the tables
  underneath.
- **`mix ash.codegen` must never emit a statement mentioning `legacy`.** That is
  enforced by a test, not by convention — see
  `test/ash_enterprise/legacy/codegen_isolation_test.exs`.

The one deliberate exception arrives at the expand step (plan §5, step 4), which
writes to `legacy.users` once, on purpose, from a hand-written migration under
`priv/legacy_migrations/`. Nothing there yet.

## The seed data is hostile on purpose

`seed.sql` contains, deliberately: two users whose emails differ only by case, a
user with no email at all, a `manager_id` pointing at a soft-deleted row, a
`roles_users` row referencing a role that no longer exists, `created_at` values
recorded in three different local time zones, and a `permissions` row whose
`action = 'manage'` has no single equivalent in the target privilege model.

Each of those is a defect the new model surfaces and the old model tolerated, and
each resolution is a decision a person has to make rather than something the
tooling can derive. That is the honest content of the demo. A clean seed would
prove nothing.

## Watching a legacy write appear

This is the demonstration the whole schema exists for. From a clean database:

```bash
devenv up -d
devenv shell -- mix ecto.reset        # create, seed legacy.*, migrate, seed tenants
devenv shell -- mix ash_enterprise.seed
devenv shell -- iex-server
```

Sign in as `admin@legacy.example` / `password1234` and open
<http://localhost:4000/app/legacy-users>. Then, in another terminal, write to the
legacy schema the way the old application would — no Ash, no changeset, no
policies:

```bash
devenv shell -- psql -h localhost -p $PGPORT -U postgres -d ash_enterprise_dev -c \
  "INSERT INTO legacy.users (login, email, first_name, last_name, state, created_at, updated_at)
   VALUES ('newhire', 'new.hire@corp.example', 'New', 'Hire', 'active', now(), now())"
```

The row appears in the table within about a second, and a banner says the legacy
application changed it. Nothing polled: the `AFTER` trigger on `legacy.users`
fired `pg_notify` on commit, `AshStrangler.Listener` re-read the row through Ash,
and the resulting notification was broadcast to the surface. See
`AshEnterpriseWeb.A2uiLive.LegacyUsers` for the chain, link by link.

`UPDATE` and `DELETE` work the same way. A `DELETE` is worth trying: because
`legacy.users.deleted_at` maps onto the attribute `AshArchival` already adds, a
row the old application soft-deletes disappears from this table without either
application having been told about the other.

## Ordering, and the one thing that will bite you

`legacy.*` has to exist **before** migrations run. The strangler migration
declares a view over `legacy.users`, so on a database where that table has never
been created it fails with `relation "legacy.users" does not exist`.

The `setup`, `ecto.setup` and `test` aliases in `mix.exs` sequence this for you.
A bare `mix ecto.migrate` on a fresh database does not — run
`mix ash_enterprise.legacy.setup` first.
