<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" style="height:64px;margin-right:32px"/>

# I'm wondering if, you know, Ash is great in terms of providing notifications, automated notifications over GraphQL or live sockets whenever there's a change to the database. But if there's multiple applications writing to the database, and one of them is this whole Node.js app, you know, is there an established means of having like Postgres triggers and listen and notify so that if an edit happens to the underlying Postgres data, that our Ash kind of parallel API is able to tackle those notifications rather than having all cooperating apps?

Great question. Ash does excel at providing real-time notifications through Phoenix PubSub and LiveView, but it relies on changes being broadcast through the Elixir layer. If you have other apps, like your Node.js app, writing directly to Postgres, you can still tap into Postgres’s own NOTIFY/LISTEN mechanism. You’d set up triggers in Postgres that fire a NOTIFY event whenever a row changes. Then, in your Elixir app, you can set up a listener process to receive those notifications and broadcast them through Phoenix channels or LiveView. This way, your Ash-based API can still react to changes regardless of which app made them. It does require some setup and understanding of Postgres triggers and the Elixir Postgrex library, but it’s a known pattern for bridging multiple writers to one database.

---

# Is there any established tooling in the Ash elixir space and maybe an Ash extension for Ash Postgres or anything like that to make it trivial to kind of declaratively state which resources need to have trigger and notify set up on?

From what I've found, there doesn't appear to be an established Ash extension or out-of-the-box tooling that declaratively sets up Postgres triggers and NOTIFY/LISTEN integration for you based on your Ash resources. Ash has a notion of notifiers that operate after its own transactions, and you can write custom notifiers, but there’s no built-in solution that automatically creates database-level triggers or listens for notifications from external writers.

Most developers who need to integrate Postgres triggers and NOTIFY with their Elixir/Ash app end up manually setting up the triggers in Postgres and using something like the Postgrex.Notifications module in Elixir to listen for those events. From there, you can wire the events into your Ash resources or Phoenix channels. It’s a bit more manual, but it gives you control over what gets triggered and how the notifications are handled.
<span style="display:none">[^2_1][^2_10][^2_2][^2_3][^2_4][^2_5][^2_6][^2_7][^2_8][^2_9]</span>

<div align="center">⁂</div>

[^2_1]: https://ash-project.github.io/ash/notifiers.html

[^2_2]: https://hex.pm/packages/ash/2.0.0-rc.5/files/documentation/topics/notifiers.md

[^2_3]: https://www.postgresql.org/docs/current/sql-notify.html

[^2_4]: https://peterullrich.com/listen-to-database-changes-with-postgres-triggers-and-elixir

[^2_5]: https://ash.hexdocs.pm/1.44.2/notifiers.html

[^2_6]: https://hexdocs.pm/ash_postgres/get-started-with-ash-postgres.html

[^2_7]: https://github.com/ash-project/ash_postgres/blob/main/lib/repo.ex

[^2_8]: https://gist.github.com/goliatone/5fbeb1912e5937e8e3cf94618be9bebf

[^2_9]: https://elixirforum.com/t/replace-pg-notify-with-pubsub-broadcast/51547

[^2_10]: https://www.reddit.com/r/PostgreSQL/comments/1l8bb13/is_it_possible_to_trigger_postgres_notification/


---

# Okay, well how about you like read everything you can find on the web about the Ash way, the kind of ideology around Ash applications, and then let's propose what the most idiomatic Ash extension might be to introduce this functionality as kind of like a first-class ability within the Elixir Ash community ecosystem, specifically kind of targeted at using it to strangler-fig away from a legacy system.

From what I’ve found, the Ash framework is built around a set of guiding principles. It emphasizes being declarative and resource-oriented, encouraging you to describe what your application should do rather than how to do it. Ash aims to be extensible and composable, acting as a “spinal cord” for your application that can coordinate with other libraries. It prefers explicit configuration over convention, focuses on pragmatic solutions that derive logic rather than hand-write it, and sees resources as the source of truth for your domain. The philosophy is about coordination and flexibility: Ash doesn’t lock you into a stack, but gives you the tools to build and extend as you need, letting you drop down to the underlying libraries when necessary.

With that in mind, an idiomatic Ash extension to handle Postgres triggers and notifications would likely allow you to declaratively attach that functionality to your resources. For example, you might specify in the resource configuration that certain events should be broadcast when changes occur. The extension could handle generating the necessary Postgres triggers, setting up an Elixir listener using Postgrex to LISTEN for notifications, and then broadcasting those changes through Phoenix PubSub or LiveView. It would stay true to Ash’s ideology by being declarative—developers configure the desired behavior in the resource, and the extension handles the underlying implementation. And it would be extensible and composable, complementing other parts of the Elixir ecosystem, not replacing them.
<span style="display:none">[^3_1][^3_10][^3_2][^3_3][^3_4][^3_5][^3_6][^3_7][^3_8][^3_9]</span>

<div align="center">⁂</div>

[^3_1]: https://github.com/ash-project/ash/blob/main/documentation/topics/about_ash/design-principles.md

[^3_2]: https://www.joekoski.com/blog/2025/10/02/ash-misconception.html

[^3_3]: https://github.com/ash-project/ash

[^3_4]: https://www.joekoski.com/blog/2025/10/06/ash-coordination.html

[^3_5]: https://dev.to/adamanq/ash-framework-introduction-3lm3

[^3_6]: https://media.pragprog.com/titles/ldash/preface.pdf

[^3_7]: https://www.youtube.com/watch?v=1aJZ7HbDgyw

[^3_8]: https://www.youtube.com/watch?v=2U3vQHXCF0s

[^3_9]: https://github.com/ash-project/ash/blob/v3.5.6/documentation/topics/about_ash/what-is-ash.md

[^3_10]: https://alembic.com.au/ash-framework


---

# Okay, well how about you like read everything you can find on the web about the Ash way, the kind of ideology around Ash applications, and then let's propose what the most idiomatic Ash extension might be to introduce this functionality as kind of like a first-class ability within the Elixir Ash community ecosystem, specifically kind of targeted at using it to strangler-fig away from a legacy system.

Now I have a solid grounding in the Ash way. Here's my proposed design.

## The Ash Way, Applied Here

Ash's core ideology is "model your domain, derive the rest": resources are the single, introspectable source of truth, and extensions (AshPostgres, AshGraphql, AshCloak) layer behavior on top through declarative configuration rather than hand-written code [^4_1][^4_2]. Ash explicitly positions itself as a "spinal cord" for the application — coordinating other libraries like Ecto, Oban, and Absinthe rather than replacing them, with "escape hatches all the way down" so you can drop to Ecto or raw SQL when needed [^4_2]. Ash already has a first-class notifier abstraction, `Ash.Notifier`, which fires after transactions commit and includes a built-in `Ash.Notifier.PubSub` [^4_3]. The gap is exactly what you identified: notifiers only fire when changes flow *through* Ash actions — external writers bypass them entirely.

## Proposal: `AshPostgresNotify`

An extension following the AshCloak/AshOban pattern: you add it to a resource's `extensions` list and declare intent in a DSL block; everything else is derived.

```elixir
defmodule MyApp.Blog.Post do
  use Ash.Resource,
    domain: MyApp.Blog,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPostgresNotify]

  postgres_notify do
    # declares: emit a notification for inserts/updates/deletes
    # regardless of which process or application made the write
    notify_on [:create, :update, :destroy]
    channel_prefix "blog:posts"
  end
end
```

The extension would be composed of three pieces, each mapping to an existing Ash concept:

### Trigger generation via migrations

The most Ash-native part. AshPostgres already generates migrations by diffing resource definitions against the database, so `AshPostgresNotify` would hook into that generator to emit `CREATE TRIGGER` and `pg_notify()` statements for resources declaring `postgres_notify` — keeping the declarative source of truth in the resource, with Postgres artifacts derived automatically.

### A supervised LISTEN process

An OTP process (wrapping `Postgrex.Notifications`) started under the repo's supervision tree per domain, listening on channels derived from resource introspection. This fits Ash's "spinal cord" model — it coordinates Postgrex rather than reinventing it.

### Rehydrating into Ash.Notifier.Notification

The crucial idiomatic move: when a Postgres notification arrives, the listener loads the record through Ash (respecting tenant, authorization-bypass reads, and multitenancy) and synthesizes a standard `Ash.Notifier.Notification` struct, then routes it through the resource's *existing* notifiers — `Ash.Notifier.PubSub`, custom notifiers, anything [^4_3]. This means downstream consumers (LiveViews, channels, GraphQL subscriptions) can't tell whether a change originated from an Ash action or your legacy Node.js app. That's the key to making it a first-class citizen rather than a parallel mechanism.

## The Strangler-Fig Angle

This design is almost purpose-built for incremental migration away from a legacy system:

- **Phase 1**: Legacy app owns the writes. Ash resources are read models over shared tables, and `AshPostgresNotify` gives you real-time reactivity with zero changes to the legacy app — the triggers do the work.
- **Phase 2**: Migrate write paths one action at a time into Ash. Both paths now funnel into the same notification stream, so consumers never notice the transition.
- **Phase 3**: Once the legacy app stops writing, the triggers become redundant (Ash notifiers already cover action-originated changes), and you disable them per-resource with a config flag — a graceful off-ramp.

There are honest caveats: `pg_notify` payloads are capped at 8KB and are at-most-once (a disconnected listener misses events), so payloads should carry only the primary key with the listener re-fetching through Ash — which conveniently is also what keeps authorization and calculations correct. And per Ash's own guidance, "at most once" effects are exactly what notifiers are for; guaranteed delivery would call for an Oban-style transactional job instead [^4_3].

No such extension exists today in the official ash-project ecosystem that I could find [^4_4] — so this would be a genuinely novel contribution, and the Ash community actively encourages third-party extensions built on the same Spark DSL toolkit that powers the official ones [^4_2].

Want me to sketch out the actual module structure and DSL definition using Spark, so you have a starting skeleton for the extension?
<span style="display:none">[^4_10][^4_11][^4_12][^4_13][^4_14][^4_15][^4_5][^4_6][^4_7][^4_8][^4_9]</span>

<div align="center">⁂</div>

[^4_1]: https://ash-hq.org/

[^4_2]: https://hexdocs.pm/ash/what-is-ash.html

[^4_3]: https://hexdocs.pm/ash/notifiers.html

[^4_4]: https://github.com/ash-project/ash

[^4_5]: https://blog.appsignal.com/2026/01/13/domains-and-resources-in-ash-for-elixir.html

[^4_6]: https://btihen.dev/posts/elixir/discovering_ash_framework_2_1/

[^4_7]: https://elixirforum.com/t/marketing-ash-why-you-should-use-ash/71487

[^4_8]: https://www.youtube.com/watch?v=zM_-Y4diVFw

[^4_9]: https://alembic.com.au/blog/essence-of-ash-framework

[^4_10]: https://github.com/ash-project/ash/blob/main/CHANGELOG.md

[^4_11]: https://news.ycombinator.com/item?id=37629719

[^4_12]: https://github.com/ash-project/ash_postgres/blob/main/documentation/topics/development/upgrading-to-2.0.md

[^4_13]: https://news.ycombinator.com/item?id=43945477

[^4_14]: https://ash-hq.org/forum/support/1100555822079148102

[^4_15]: https://elixir-phoenix-ash.com/elixir/


---

# Great! Now, what if we wanted to define a new "next generation" data model as a view on top of the legacy schema. How to incorporate that into our ash plan?

This is a beautiful fit for the strangler-fig strategy, and Ash's existing tooling already has almost everything you need. Here's how to weave views-on-legacy-schema into the plan.

## Why Views Fit the Ash Philosophy

Ash's core tenet is that resources are the source of truth and everything else is derived [^5_1]. Views are the database-level embodiment of that same idea: they present a stable, clean interface over tables whose shape you don't control. PostgreSQL's own documentation calls views a "key aspect of good SQL database design" because they "encapsulate the details of the structure of your tables, which might change as your application evolves, behind consistent interfaces" [^5_2]. Aligning your Ash resources against views rather than raw legacy tables means your domain model is insulated from legacy schema churn — exactly the insulation the strangler-fig pattern needs.

## The Key Insight: `table` Works on Views

AshPostgres's `postgres` block has a `table` option that accepts any relation name — it doesn't distinguish between a physical table and a view [^5_3]. So if you create a view called `next_gen_customers` that projects and reshapes columns from the legacy `cust_master` and `cust_contact` tables, you simply point your Ash resource at it:

```elixir
defmodule MyApp.NextGen.Customer do
  use Ash.Resource,
    domain: MyApp.NextGen,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPostgresNotify]

  attributes do
    uuid_primary_key :id
    attribute :email, :string
    attribute :full_name, :string
    attribute :tier, :string
  end

  postgres do
    repo MyApp.Repo
    table "next_gen_customers"   # ← a view, not a table
    migrate? true                # Ash owns the view definition
  end

  postgres_notify do
    notify_on [:create, :update, :destroy]
    channel_prefix "next_gen:customers"
  end
end
```


## Declaring Views via `custom_statements`

AshPostgres already has a first-class `custom_statements` section in its DSL that injects raw SQL into generated migrations, with explicit `up` and `down` strings [^5_3]. This is the idiomatic place to declare your view:

```elixir
postgres do
  repo MyApp.Repo
  table "next_gen_customers"
  migrate? true

  custom_statements do
    statement :create_next_gen_customers_view do
      up """
      CREATE OR REPLACE VIEW next_gen_customers AS
      SELECT
        cm.cust_id    AS id,
        cm.cust_email AS email,
        (cm.first_name || ' ' || cm.last_name) AS full_name,
        cm.tier_code  AS tier
      FROM legacy.cust_master cm
      LEFT JOIN legacy.cust_contact cc ON cm.cust_id = cc.cust_id
      """
      down "DROP VIEW IF EXISTS next_gen_customers"
    end
  end
end
```

Ash's migration generator handles ordering — `down` statements run first, `up` statements last — and Ash explicitly warns that custom statements may require manual intervention if they depend on other migration artifacts [^5_3]. This is a reasonable trade-off: you get declarative view definitions in your resource file, checked into version control, while keeping full control over the SQL.

## Read-Only vs. Writable Views

This is where the architecture gets interesting for the strangler-fig migration:

### Simple single-table views — automatically updatable

PostgreSQL automatically makes views updatable when they select from a single base table with no aggregation, DISTINCT, or computed columns [^5_4]. If your view is a simple projection of one legacy table, Ash's create/update/destroy actions will work without any extra plumbing — Postgres routes the writes straight to the base table.

### Complex views — INSTEAD OF triggers

When your view joins multiple tables or computes columns, PostgreSQL requires `INSTEAD OF` triggers to route writes back to the base tables [^5_5][^5_6]. These are declared as additional `custom_statements`:

```elixir
statement :create_customer_insert_trigger do
  up """
  CREATE OR REPLACE FUNCTION next_gen_customer_insert() RETURNS trigger AS $$
  BEGIN
    INSERT INTO legacy.cust_master (cust_id, cust_email, first_name, last_name, tier_code)
    VALUES (NEW.id, NEW.email, split_part(NEW.full_name, ' ', 1),
            split_part(NEW.full_name, ' ', 2), NEW.tier);
    RETURN NEW;
  END;
  $$ LANGUAGE plpgsql;

  CREATE TRIGGER next_gen_customer_insert_trg
  INSTEAD OF INSERT ON next_gen_customers
  FOR EACH ROW EXECUTE FUNCTION next_gen_customer_insert();
  """
  down "DROP TRIGGER IF EXISTS next_gen_customer_insert_trg ON next_gen_customers; DROP FUNCTION IF EXISTS next_gen_customer_insert();"
end
```

The beauty of `INSTEAD OF` triggers is that Ash is completely unaware they exist — it issues a standard `INSERT INTO next_gen_customers ...`, and Postgres transparently routes it to the legacy tables [^5_5]. This means your Ash actions, validations, policies, and GraphQL resolvers all work as if the view were a real table.

## How This Integrates with AshPostgresNotify

The pieces fit together naturally because of how Postgres trigger scoping works:

- **NOTIFY triggers go on the base tables**, not the views. When your legacy Node.js app writes to `legacy.cust_master`, the trigger fires `pg_notify('next_gen:customers', row_to_json(NEW)::text)`.
- **The LISTEN process** receives the notification, loads the record *through Ash* — which reads from the `next_gen_customers` view, automatically applying your reshaped columns, calculations, and policies.
- **The synthesized notification** flows through the resource's existing notifiers, reaching LiveViews and GraphQL subscriptions.

The legacy app never knows the view or the Ash layer exists. It writes to its tables. The triggers capture the change. The view presents the new shape. Ash rehydrates and broadcasts. Consumers stay reactive.

## The Migration Arc

| Phase | Legacy writes | Ash writes | View role | Trigger role |
| :-- | :-- | :-- | :-- | :-- |
| 1 — Read models | ✅ (owns tables) | ❌ | Reshape legacy for Ash reads | NOTIFY on base tables |
| 2 — Shared writes | ✅ | ✅ (via INSTEAD OF) | Route Ash writes to base tables | Both NOTIFY and INSTEAD OF |
| 3 — Ash owns data | ❌ | ✅ (direct to tables) | View dropped; resource points at table | NOTIFY replaced by Ash notifiers |

In Phase 1, you create views and point Ash resources at them with only read actions enabled — your Ash API becomes a real-time read model over the legacy system. In Phase 2, you add `INSTEAD OF` triggers and enable Ash write actions, so both the legacy app and Ash can write to the same underlying tables through different interfaces. In Phase 3, once the legacy app is decommissioned, you drop the views, point the resources directly at the tables (or new tables Ash now manages), and the `INSTEAD OF` triggers become unnecessary — Ash's own notifiers handle change propagation natively.

## Working with Existing Databases Workflow

AshPostgres's `--fragments` and `--no-migrations` generator is designed for exactly this scenario — it introspects existing tables/views and generates resource files with `migrate? false`, so Ash doesn't try to manage schema it doesn't own [^5_7]. You'd use this for the *base legacy tables*, while your *next-gen views* use `migrate? true` with `custom_statements` so Ash owns the view definitions. This gives you a clean separation: Ash respects the legacy schema as immutable while actively managing the new view layer on top.

One thing to watch: `INSTEAD OF` triggers add complexity to debugging because writes go through an indirection layer. The Ash community's approach to this aligns with the framework's philosophy of "escape hatches all the way down" — you can always drop to raw SQL or Ecto when you need to inspect what's actually hitting the database.

Want me to sketch out a concrete resource file showing a complete next-gen view resource with both the view definition, the INSTEAD OF trigger, and the notify block all in one declarative module?
<span style="display:none">[^5_10][^5_11][^5_12][^5_13][^5_14][^5_15][^5_16][^5_17][^5_18][^5_19][^5_20][^5_21][^5_22][^5_23][^5_24][^5_25][^5_26][^5_27][^5_28][^5_29][^5_30][^5_31][^5_32][^5_33][^5_34][^5_35][^5_36][^5_37][^5_38][^5_39][^5_40][^5_41][^5_42][^5_8][^5_9]</span>

<div align="center">⁂</div>

[^5_1]: https://ash-hq.org/

[^5_2]: https://www.postgresql.org/docs/current/tutorial-views.html

[^5_3]: https://hexdocs.pm/ash_postgres/dsl-ashpostgres-datalayer.html

[^5_4]: https://www.bytebase.com/reference/postgres/how-to/how-to-create-view-postgres/

[^5_5]: https://www.datacamp.com/doc/postgresql/instead-of-triggers

[^5_6]: https://www.dbi-services.com/blog/can-i-do-it-with-postgresql-18-instead-of-triggers-on-views/

[^5_7]: https://hexdocs.pm/ash_postgres/working-with-existing-databases.html

[^5_8]: https://www.postgresql.org/docs/current/sql-createview.html

[^5_9]: https://medium.com/@ntepp.marcus/migrating-from-monolith-to-microservices-the-strangler-fig-pattern-7097167f8e49

[^5_10]: https://github.com/ash-project/ash

[^5_11]: https://neon.com/postgresql/postgresql-views

[^5_12]: https://dev.to/arnavsharma2711/views-in-postgresql-a-complete-guide-with-examples-375j

[^5_13]: https://oneuptime.com/blog/post/2026-01-24-strangler-fig-migration-pattern/view

[^5_14]: https://www.geeksforgeeks.org/postgresql/postgresql-managing-views/

[^5_15]: https://elixirforum.com/t/ash-framework-a-declarative-resource-oriented-application-development-framework-for-elixir/51119

[^5_16]: https://www.postgresql.org/docs/current/views.html

[^5_17]: https://medium.com/@lambert.kamaro/part-5-ash-framework-for-phoenix-developers-home-page-calculations-82a0ec6532df

[^5_18]: https://hexdocs.pm/ash/dsl-ash-resource.html

[^5_19]: https://neon.com/postgresql/postgresql-views/managing-postgresql-views

[^5_20]: https://github.com/ash-project/ash_postgres/blob/main/documentation/topics/development/migrations-and-tasks.md

[^5_21]: https://preview.hex.pm/preview/ash_postgres/show/documentation/tutorials/get-started-with-ash-postgres.md

[^5_22]: https://elixirforum.com/t/select-fields-in-read-action/65556

[^5_23]: https://github.com/ash-project/ash_postgres/blob/main/documentation/topics/development/upgrading-to-postgres-18.md

[^5_24]: https://elixirforum.com/t/extensions-in-ash-postgres-database/73701

[^5_25]: https://medium.com/@westbaystars/multilingual-names-with-postgres-elixir-and-ash-6951c729bb43

[^5_26]: https://medium.com/@lambert.kamaro/ash-resource-preparations-what-they-are-and-how-they-benefit-you-800d86fa9246

[^5_27]: https://github.com/ash-project/ash_postgres/issues/490

[^5_28]: https://docs.hex-rays.com/user-guide/user-interface/subviews

[^5_29]: https://hexdocs.pm/ash_postgres/Mix.Tasks.AshPostgres.GenerateMigrations.html

[^5_30]: https://medium.com/@antoniodipinto/zero-downtime-schema-migrations-in-postgresql-c138017e7f90

[^5_31]: https://hex-rays.com/wp-content/uploads/2019/12/debugging_qemu.pdf

[^5_32]: https://hexdocs.pm/ash/relationships.html

[^5_33]: https://www.postgresql.org/docs/current/rules-views.html

[^5_34]: https://www.postgresql.org/docs/current/sql-createtrigger.html

[^5_35]: https://neon.com/postgresql/postgresql-triggers/postgresql-instead-of-triggers

[^5_36]: https://michaeljswart.com/2012/10/triggers-on-views-what-for/

[^5_37]: https://dba.stackexchange.com/questions/63941/i-have-an-instead-of-trigger-but-postgresql-still-complains-while-i-insert-into

[^5_38]: https://www.answeroverflow.com/m/1394664336559046776

[^5_39]: https://stackoverflow.com/questions/55490296/trigger-on-view-in-postgresql-doesnt-trigger

[^5_40]: https://stackoverflow.com/questions/451096/execute-a-trigger-on-a-view-in-postgresql

[^5_41]: https://medium.com/learning-sql/indexes-views-and-triggers-in-postgresql-e88f46f404be

[^5_42]: https://medium.com/@lambert.kamaro/part-36-the-proven-way-to-run-migrations-in-an-ash-app-production-release-4311a0d36831


---

# I like your thinking, but in order to align with ashes philosophy, I think we need a definition dividend driven declarative mapping between the Legacy schema and the new schema as part of the ash code base. In order to be able to have some new ash extension, we define maintain the views as well as ensure that we manage the weirdness around notification around inserts and such at the Legacy layer Legacy database table level and ensuring that our ash application is primarily operating on the new schema. That means even like insert notifications and stuff need to be mapped between the two. Anyway, think it through and let me know how to approach it

You're pushing toward something genuinely powerful — a single declarative mapping that becomes the source of truth from which *everything else* is derived: the view SQL, the INSTEAD OF write triggers, the NOTIFY triggers on legacy tables, and the notification routing. Let me think this through properly.

## The Core Principle: One Declaration, Many Derivations

Ash's extension model is built on Spark DSL transformers that read declarative configuration and modify the resource's compiled state at build time [^6_1]. AshPostgres already demonstrates this pattern perfectly: its `custom_statements` section lets you declare SQL that gets injected into generated migrations, with the migration generator picking up those statements automatically [^6_2][^6_3]. The insight is that your extension's transformer can *programmatically generate* `custom_statements` from a higher-level declarative mapping, rather than requiring developers to hand-write SQL.

This means you declare the mapping once, and the extension derives four separate artifacts:

## The Declarative Mapping DSL

```elixir
defmodule MyApp.NextGen.Customer do
  use Ash.Resource,
    domain: MyApp.NextGen,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPostgresNotify]

  attributes do
    uuid_primary_key :id
    attribute :email, :string
    attribute :full_name, :string
    attribute :tier, :string
  end

  postgres do
    repo MyApp.Repo
    table "next_gen_customers"
    migrate? true
  end

  postgres_notify do
    legacy_source "legacy.cust_master" do
      primary_key :cust_id

      field_mapping :id, "cust_id"
      field_mapping :email, "cust_email"
      field_mapping :full_name, "first_name || ' ' || last_name"
      field_mapping :tier, "tier_code"

      join "legacy.cust_contact",
        on: "cust_master.cust_id = cust_contact.cust_id",
        fields: [contact_phone: "phone_number"]
    end

    notify_on [:create, :update, :destroy]
    channel_prefix "next_gen:customers"
  end
end
```

Every piece of downstream SQL and Elixir behavior is derived from this block. The developer never writes a `CREATE VIEW` or `CREATE TRIGGER` statement — the transformer generates them [^6_1].

## What the Transformer Derives

The extension's Spark transformer reads the `legacy_source` entity and its `field_mapping` children at compile time, then injects four categories of `custom_statements` into the resource's postgres configuration. Since AshPostgres's migration generator already processes `custom_statements` into ordered up/down migrations [^6_2], these get checked into version control and applied via the normal `mix ash.codegen` / `mix ash.migrate` workflow [^6_4].

### 1. The View Definition

Derived directly from the field mappings:

```sql
CREATE OR REPLACE VIEW next_gen_customers AS
SELECT
  cust_id    AS id,
  cust_email AS email,
  first_name || ' ' || last_name AS full_name,
  tier_code  AS tier,
  cc.phone_number AS contact_phone
FROM legacy.cust_master cm
LEFT JOIN legacy.cust_contact cc ON cm.cust_id = cc.cust_id
```

The transformer iterates the `field_mapping` entities, constructing the SELECT list by mapping each new attribute name to its legacy SQL expression, and appends JOINs from the `join` entities.

### 2. INSTEAD OF Write Triggers

For each action in `notify_on`, the transformer generates a PL/pgSQL function and `INSTEAD OF` trigger on the view. This is the **reverse mapping** — taking new-schema column values and writing them back to legacy columns:

```sql
-- INSTEAD OF INSERT (derived from the same field_mapping, reversed)
CREATE FUNCTION next_gen_customers_insert() RETURNS trigger AS $$
BEGIN
  INSERT INTO legacy.cust_master (cust_id, cust_email, first_name, last_name, tier_code)
  VALUES (NEW.id, NEW.email,
          split_part(NEW.full_name, ' ', 1),
          split_part(NEW.full_name, ' ', 2),
          NEW.tier);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER next_gen_customers_insert_trg
INSTEAD OF INSERT ON next_gen_customers
FOR EACH ROW EXECUTE FUNCTION next_gen_customers_insert();
```

The critical design question here is **decomposability**: computed expressions like `first_name || ' ' || last_name` are not trivially reversible. The extension needs to handle this. There are two approaches:

- **Simple mappings** (direct column references like `email → cust_email`) generate clean bidirectional triggers automatically.
- **Computed mappings** (like `full_name → first_name || ' ' || last_name`) require either a `reverse_mapping` declaration or a flag marking them as read-only (writable? false in Ash terms), so the INSTEAD OF trigger omits them on writes and Ash's validations catch the attempt.

This mirrors Ash's own philosophy: the common case is fully derived, and complex cases have explicit escape hatches rather than silent failures.

### 3. NOTIFY Triggers on Legacy Base Tables

These are the triggers that fire when the legacy Node.js app writes directly to the legacy tables. The transformer generates `AFTER INSERT/UPDATE/DELETE` triggers on the legacy base table:

```sql
CREATE OR REPLACE FUNCTION notify_next_gen_customers() RETURNS trigger AS $$
BEGIN
  PERFORM pg_notify(
    'next_gen:customers',
    json_build_object(
      'action', TG_OP,
      'legacy_pk', CASE TG_OP WHEN 'DELETE' THEN OLD.cust_id ELSE NEW.cust_id END
    )::text
  );
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER legacy_cust_master_notify
AFTER INSERT OR UPDATE OR DELETE ON legacy.cust_master
FOR EACH ROW EXECUTE FUNCTION notify_next_gen_customers();
```

The payload is deliberately minimal — just the action type and the legacy primary key. This sidesteps the 8KB `pg_notify` payload limit and, more importantly, forces the listener to re-fetch through Ash, which means the record is loaded from the view with all calculations, policies, and relationships applied correctly [^6_5].

### 4. The Notification Listener and Mapping

A supervised GenServer wrapping `Postgrex.Notifications` maintains a compile-time-derived mapping table: legacy table → new-gen resource → channel. When a notification arrives, it:

1. Looks up the resource from the channel name
2. Maps the `legacy_pk` to the resource's primary key (using the same `field_mapping` that defined the view)
3. Loads the record through Ash's read actions (respecting tenant, policies, calculations)
4. Synthesizes a standard `Ash.Notifier.Notification` struct with the appropriate `action` field (`:create`, `:update`, or `:destroy`) [^6_5]
5. Routes it through the resource's existing notifiers — `Ash.Notifier.PubSub`, custom notifiers, anything

Downstream consumers (LiveViews, GraphQL subscriptions, channels) receive identical notification structs regardless of whether the write came from Ash or the legacy app. This is the "derivation dividend": one declarative mapping produces both the read model (the view) and the reactive model (the notification pipeline).

## The Double-Notification Problem

When Ash itself writes through the view (via INSTEAD OF triggers), the legacy table's NOTIFY trigger also fires — producing a duplicate of what Ash's own notifiers already emitted. The extension must handle this. Two approaches, each with different trade-offs:

### Approach A: Unified NOTIFY Path (simpler, recommended for migration)

Set `skip_internal_notifiers? true` in the DSL. Ash's own notifiers are suppressed for resources using `postgres_notify`, and *all* notifications — internal and external — flow through the PG NOTIFY → listener → Ash.Notifier.Notification path. This provides a uniform notification contract and simpler reasoning, at the cost of a small latency overhead on internal writes (one extra round-trip through Postgres). This is the idiomatic choice during strangler-fig migration: consistency matters more than microsecond latency, and once the legacy app is decommissioned, you flip the flag off and Ash notifiers take over directly.

### Approach B: GUC Suppression (optimized, more complex)

The extension sets a transaction-local GUC variable when Ash originates a write:

```sql
SET LOCAL ash.originated = true;
```

The NOTIFY trigger checks this and skips:

```sql
IF current_setting('ash.originated', true) = 'true' THEN
  RETURN NEW;  -- Ash's own notifiers will handle it
END IF;
```

This eliminates double notifications while keeping internal writes fast, but introduces hidden coupling between the Elixir and SQL layers. It's the right optimization for Phase 3 when the legacy app is gone and you want native Ash notifier speed — but it's premature complexity during active migration.

## The Full Migration Arc, Revisited

| Phase | Legacy writes | Ash writes | View | INSTEAD OF triggers | NOTIFY triggers | Internal notifiers |
| :-- | :--: | :--: | :--: | :--: | :--: | :--: |
| 1 — Shadow reads | ✅ | ❌ | Read model | ❌ | ✅ (active) | ❌ |
| 2 — Shared writes | ✅ | ✅ | Read + write | ✅ | ✅ (active) | Suppressed (Approach A) |
| 3 — Ash owns data | ❌ | ✅ (direct to table) | Dropped | Dropped | Dropped | ✅ (native) |

In Phase 1, only the view and NOTIFY triggers exist — Ash is a reactive read model over legacy data. In Phase 2, INSTEAD OF triggers are added and Ash write actions are enabled; all notifications flow through the unified PG NOTIFY path. In Phase 3, the legacy app is gone, the view and all triggers are dropped via migration, the resource's `table` points directly at either the same table (now owned by Ash) or a new Ash-managed table, and native Ash notifiers handle everything. Each transition is a config flag change and a migration, not a rewrite.

## What Makes This Idiomatic

This design follows every principle in Ash's extension-writing guide [^6_1] and AshPostgres's existing patterns [^6_2]:

- **Declarative**: The developer states the mapping; SQL is derived
- **Composable**: It layers on top of AshPostgres by injecting `custom_statements`, not by replacing the data layer
- **Escape hatches**: Simple mappings are fully automatic; computed mappings can declare `reverse_mapping` or be marked read-only
- **Source of truth**: The `postgres_notify` block is the single declaration from which views, triggers, and notification routing are all derived — change the mapping and re-run `mix ash.codegen` to generate the migration that updates everything

Want me to sketch the actual Spark DSL entity and transformer module structure so you have a concrete starting point for implementation?
<span style="display:none">[^6_10][^6_11][^6_12][^6_13][^6_14][^6_15][^6_16][^6_17][^6_18][^6_19][^6_20][^6_21][^6_22][^6_23][^6_24][^6_25][^6_26][^6_27][^6_28][^6_29][^6_6][^6_7][^6_8][^6_9]</span>

<div align="center">⁂</div>

[^6_1]: https://hexdocs.pm/ash/writing-extensions.html

[^6_2]: https://www.answeroverflow.com/m/1405241808992207073

[^6_3]: https://elixirforum.com/t/does-ash-support-defining-exclusion-constraints-on-resources-with-the-dsl/61057/2

[^6_4]: https://github.com/ash-project/ash_postgres/blob/main/documentation/topics/development/migrations-and-tasks.md

[^6_5]: https://ash.hexdocs.pm/3.4.25/Ash.Notifier.Notification.html

[^6_6]: https://github.com/ash-project/spark/blob/main/lib/spark/dsl/entity.ex

[^6_7]: https://hexdocs.pm/ash/2.10.1/extending-resources.html

[^6_8]: https://ash-hq.org/forum/support/1142429710907867247

[^6_9]: https://github.com/ash-project/spark/blob/main/lib/spark/dsl/extension.ex

[^6_10]: https://hexdocs.pm/spark/get-started-with-spark.html

[^6_11]: https://hexdocs.pm/ash_postgres/1.2.4/AshPostgres.DataLayer.html

[^6_12]: https://github.com/ash-project/ash/blob/main/documentation/dsls/DSL-Ash.Resource.md

[^6_13]: https://ash-hq.org/forum/support/1128225000600633344

[^6_14]: https://github.com/ash-project/ash

[^6_15]: https://ash-hq.org/forum/support/1072612437376897106

[^6_16]: https://github.com/ash-project/spark/issues/47

[^6_17]: https://hexdocs.pm/spark/Spark.Dsl.html

[^6_18]: https://www.answeroverflow.com/m/1122295878431023235

[^6_19]: https://ash-hq.com/forum/support/1093178338337636435

[^6_20]: https://hexdocs.pm/ash_postgres/dsl-ashpostgres-datalayer.html

[^6_21]: https://github.com/ash-project/spark/blob/main/lib/spark/dsl/transformer.ex

[^6_22]: https://preview.hex.pm/preview/ash_postgres/1.5.21/show/documentation/dsls/DSL:-AshPostgres.DataLayer.md

[^6_23]: https://ash.hexdocs.pm/3.4.20/notifiers.html

[^6_24]: https://hex.pm/packages/ash/1.34.1/files/lib/ash/notifier/notifier.ex

[^6_25]: https://github.com/ash-project/ash/blob/main/documentation/topics/resources/notifiers.md

[^6_26]: https://github.com/ash-project/ash/blob/main/CHANGELOG.md

[^6_27]: https://github.com/ash-project/ash_postgres

[^6_28]: https://docs.aws.amazon.com/sdk-for-cpp/latest/api/aws-cpp-sdk-notifications/html/_notification_configuration_structure_8h_source.html

[^6_29]: https://www.youtube.com/watch?v=GtsL_lIis4Q


---

# Okay, great. I also know that the existing application is a react application using restful routes served by a node.js Express app. I can imagine a path forward where I also ensure that we're serving the Legacy rest API from the next generation. Ash stranglerfig setup such that the react app can remain as a legacy front end as needed, but eventually replaced by Phoenix. Live view or whatever other tooling makes sense

This is the missing layer — you've now got the data layer (views), the notification layer (triggers/NOTIFY), and now the API layer. Let me lay out how it fits together.

## The Three-Layer Strangler Fig

Your architecture now has three migration surfaces, each strangler-figged independently but sharing the same declarative resource definitions:


| Layer | Legacy | Ash replacement | Key mechanism |
| :-- | :-- | :-- | :-- |
| Data | Legacy tables | Views + INSTEAD OF triggers | `AshPostgresNotify` field mappings |
| Notifications | None (polling?) | PG NOTIFY → Ash notifiers | NOTIFY triggers on base tables |
| API | Express REST routes | Phoenix serving Ash actions | Reverse proxy → incremental intercept |

The beauty is that the resource file is the single source of truth for all three. The field mappings drive the view SQL, the trigger generation, *and* the API serialization.

## Phase 0: The Proxy Foundation

The Elixir community has well-established tooling for exactly this pattern. The Terraform plug (later evolved into `ReverseProxyPlug`) was built specifically to "incrementally replace an API with Phoenix" by intercepting requests that Phoenix can handle and forwarding everything else to the legacy backend [^7_1][^7_2]. `ReverseProxyPlug` is the maintained version, handling raw body forwarding, header preservation, and WebSocket proxying [^7_3].

The starting Phoenix router:

```elixir
defmodule MyAppWeb.Router do
  use Phoenix.Router

  # AshJsonApi routes (Phase 2+ — initially empty or minimal)
  forward "/api", MyAppWeb.JsonApiRouter

  # Catch-all: proxy everything Ash didn't handle to Express
  match :*, "/*path", MyAppWeb.LegacyProxy
end
```

```elixir
defmodule MyAppWeb.LegacyProxy do
  use ReverseProxyPlug
  # Forwards to the legacy Express app
end
```

In this phase, the React frontend talks to Phoenix, which transparently proxies to Express. The React app sees no difference. You now have an interception point [^7_1].

## Phase 1: Intercepting Reads

As you model resources in Ash (backed by your next-gen views), you intercept their GET routes and serve them directly from Ash — serialized in the **legacy format the React app expects**. This is the critical constraint: the React app must not know the backend changed.

The challenge is that AshJsonApi generates JSON:API-spec-compliant responses (`{ data: { type: "customers", id: "1", attributes: { ... } } }`), which is a different format from typical Express REST responses (`{ id: 1, email: "...", name: "..." }`) [^7_4]. Rather than fighting AshJsonApi's serialization, the more idiomatic approach is to call Ash actions directly from Phoenix controllers and render with custom views:

```elixir
defmodule MyAppWeb.CustomerController do
  use MyAppWeb, :controller
  alias MyApp.NextGen.Customer

  def index(conn, _params) do
    customers = Ash.read!(Customer, domain: MyApp.NextGen)
    # Serialize in the exact format the React app expects
    json(conn, Enum.map(customers, &serialize_customer/1))
  end

  def show(conn, %{"id" => id}) do
    customer = Ash.get!(Customer, id, domain: MyApp.NextGen)
    json(conn, serialize_customer(customer))
  end

  defp serialize_customer(c) do
    %{
      "id" => c.id,
      "email" => c.email,
      "fullName" => c.full_name,   # camelCase — matching legacy API contract
      "tier" => c.tier
    }
  end
end
```

The route is registered *before* the catch-all proxy, so Phoenix handles it instead of forwarding:

```elixir
scope "/api", MyAppWeb do
  get "/customers", CustomerController, :index
  get "/customers/:id", CustomerController, :show
end

match :*, "/*path", MyAppWeb.LegacyProxy
```

The React app hits `GET /api/customers` and gets back the same JSON shape it always got — but now the data flows through Ash, which reads from the view, which projects from the legacy tables. If the legacy app writes a customer record, the NOTIFY trigger fires, Ash rehydrates it, and the next React request sees the update [^7_3].

## Phase 2: Intercepting Writes

Same pattern for POST/PUT/DELETE — Phoenix controllers call Ash actions, which write through the INSTEAD OF triggers to the legacy tables:

```elixir
def create(conn, params) do
  customer = MyApp.NextGen.Customer
    |> Ash.Changeset.for_create(:create, %{
      email: params["email"],
      full_name: params["fullName"],
      tier: params["tier"]
    })
    |> Ash.create!()

  conn
  |> put_status(:created)
  |> json(serialize_customer(customer))
end
```

The React app sends the same POST it always sent. Ash creates the record through the view's INSTEAD OF trigger, which writes to the legacy tables. The NOTIFY trigger fires, the listener synthesizes an `Ash.Notifier.Notification`, and any Phoenix channels or LiveViews subscribed to that resource receive the update in real time — all from the same declarative resource definition [^7_5].

## The Declarative Serialization Layer

Hand-writing controllers and serializers per resource is fine for a handful, but it violates the "derive, don't hand-write" principle. The idiomatic move is to make the legacy API contract part of your extension's DSL, alongside the field mappings you already declared:

```elixir
postgres_notify do
  legacy_source "legacy.cust_master" do
    primary_key :cust_id
    field_mapping :id, "cust_id"
    field_mapping :email, "cust_email"
    field_mapping :full_name, "first_name || ' ' || last_name"
    field_mapping :tier, "tier_code"
  end

  notify_on [:create, :update, :destroy]
  channel_prefix "next_gen:customers"
end

legacy_api do
  base_path "/api/customers"
  # Reuse the same attribute names, declare legacy serialization
  serialize :full_name, as: "fullName"   # camelCase for React
  serialize :id, as: "id"
  # Omit fields the React app shouldn't see
  except [:internal_tier_code]
end
```

The extension's transformer reads the `legacy_api` block and generates a Phoenix controller module and route entries at compile time, calling Ash actions and serializing responses in the declared format. The developer declares the API contract; the controller, serializer, and route are derived — same pattern as AshJsonApi deriving JSON:API endpoints from resource definitions [^7_4].

## Phase 3: Frontend Migration

Once all API routes are served by Ash through Phoenix, the Express app is decommissioned. The proxy plug is removed. Now you have options:

- **Keep the React app** consuming the legacy-format REST endpoints indefinitely — they're just Phoenix controllers now
- **Gradually introduce LiveView** for specific pages, replacing React components with server-rendered LiveView that connects directly to Ash resources through Phoenix PubSub
- **Introduce AshJsonApi or AshGraphQL** for new frontend work, serving the modern JSON:API or GraphQL format alongside the legacy-format controllers, then migrate the React app's fetch calls endpoint by endpoint

The key insight is that because your Ash resources already define the domain model, AshJsonApi and AshGraphQL can serve the same resources in their native formats *with zero additional resource configuration* — you just add the extensions and mount the routers [^7_4][^7_6]. The legacy-format controllers and the modern API endpoints coexist on the same resources, and you migrate the frontend at whatever pace makes sense.

## The Complete Migration Arc

| Phase | React frontend | Phoenix router | Express app | Legacy tables | Ash resources |
| :-- | :--: | :--: | :--: | :--: | :--: |
| 0 — Proxy | Talks to Phoenix | Everything proxied | Active | Active | Read-only views |
| 1 — Intercept reads | Unchanged | GET routes intercepted | Active | Active | Read actions live |
| 2 — Intercept writes | Unchanged | All routes intercepted | Decommissioned | Active (via triggers) | Full CRUD |
| 3 — Modern frontend | Gradually replaced | Legacy + AshJsonApi/GraphQL | Gone | Migrated to Ash-owned | Native notifiers |

The complete strangler-fig now operates at three levels simultaneously: the **data layer** migrates via views and INSTEAD OF triggers, the **notification layer** unifies via PG NOTIFY → Ash notifiers, and the **API layer** migrates via proxy interception → Ash-served endpoints → modern format. Each layer can be at a different phase, and the resource file's declarative mapping drives all three.

Want me to sketch out how the `legacy_api` DSL block would work as a Spark extension transformer that generates Phoenix controllers at compile time?
<span style="display:none">[^7_10][^7_11][^7_12][^7_13][^7_14][^7_15][^7_16][^7_17][^7_18][^7_19][^7_20][^7_21][^7_22][^7_23][^7_24][^7_25][^7_26][^7_27][^7_28][^7_29][^7_7][^7_8][^7_9]</span>

<div align="center">⁂</div>

[^7_1]: https://medium.com/@sugarpirate/rise-from-the-ashes-incremental-apis-with-phoenix-b08cd66bd142

[^7_2]: https://github.com/poteto/reverse_proxy

[^7_3]: https://hexdocs.pm/reverse_proxy_plug/ReverseProxyPlug.html

[^7_4]: https://hexdocs.pm/ash_json_api/1.3.0/getting-started-with-ash-json-api.html

[^7_5]: https://hexdocs.pm/ash_json_api/AshJsonApi.Router.html

[^7_6]: https://dev.to/adamanq/ash-ways-to-contact-ashjsonapi-ashgraphql-and-ashtypescript-c8

[^7_7]: https://github.com/ash-project/ash_json_api/blob/main/documentation/tutorials/getting-started-with-ash-json-api.md

[^7_8]: https://github.com/ash-project/ash_json_api/blob/main/documentation/topics/open-api.md

[^7_9]: https://www.answeroverflow.com/m/1141148742012121209

[^7_10]: https://elixirforum.com/t/what-is-the-right-way-to-setup-ashjsonapi/59184

[^7_11]: https://gist.github.com/zachdaniel/0b8cb27391ca37b71bf9933f465350d5

[^7_12]: https://hex.pm/packages/ash_oaskit/0.3.0/files/README.md

[^7_13]: https://elixir-phoenix-ash.com/phoenix/router.html

[^7_14]: https://thoughtbot.com/blog/building-a-phoenix-json-api

[^7_15]: https://news.lavx.hu/article/ash-elixir-rest-graphql-typescript-rpc

[^7_16]: https://preview.hex.pm/preview/ash_json_api/1.6.4/show/documentation/dsls/DSL-AshJsonApi.Domain.md

[^7_17]: https://elixirforum.com/t/how-would-i-set-host-attribute-in-plug-conn-under-reverse-proxy/35373

[^7_18]: https://stackoverflow.com/questions/33097550/how-can-i-forward-a-client-request-in-phoenix-framework-acting-as-a-proxy

[^7_19]: https://note.com/yamanetoshi/n/nde4f8507911a

[^7_20]: https://dev.to/byronsalty/adding-blog-proxy-to-a-phoenix-app-1o88

[^7_21]: https://elixirforum.com/t/how-to-detect-the-source-of-http-request/8535

[^7_22]: https://devhints.io/phoenix-conn

[^7_23]: https://www.no.lol/2016-08-12-rise-from-the-ashes-incremental-apis-with-phoenix/

[^7_24]: https://hexdocs.pm/plug_proxy/PlugProxy.html

[^7_25]: https://github.com/ash-project/ash_json_api/blob/main/lib/ash_json_api.ex

[^7_26]: https://stackoverflow.com/questions/75149258/cowboy-2-9-0-reverse-proxy-websockets

[^7_27]: https://github.com/loopsocial/phoenix_reverse_proxy

[^7_28]: https://hexdocs.pm/ash_json_api/0.1.4/index.html

[^7_29]: https://www.answeroverflow.com/m/1087881932282548284

