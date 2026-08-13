## The Core Pattern: Expand/Contract (Parallel Change)

The academic name for what you're describing is **parallel change**, also called **expand/contract**, formalized by Martin Fowler as the standard technique for evolutionary database design[^1][^2]. It decomposes a backward-incompatible schema change into three phases so that at every point in time, some deployed application version's assumptions match the schema and data actually present[^3]:

- **Expand**: Add new structure (columns, tables) additively; never alter or remove anything old. Old code keeps working unchanged[^4][^3].
- **Migrate**: Dual-write to both shapes, backfill historical rows in batches, then cut reads over to the new shape[^4][^5][^6].
- **Contract**: Once nothing references the old shape, drop it — a one-way, brief-lock operation[^7][^8].

This is precisely the theoretical foundation for writable-view-plus-`INSTEAD OF`-trigger compatibility shims: the view/trigger layer *is* the mechanism that lets both old and new application code operate against a single physical schema during the migrate phase[^9][^10].

## Writable Views + INSTEAD OF Triggers: What This Buys You

Postgres views are automatically updatable only under narrow conditions (single-table FROM, no aggregates/window functions/set ops, no GROUP BY/DISTINCT)[^9]. For anything resembling a real strangler-fig mapping — renamed columns, split/merged tables, denormalization, type coercion — you need `INSTEAD OF` triggers, which work on *any* view regardless of updatability and convert INSERT/UPDATE/DELETE on the view into arbitrary DML against the real tables[^9][^10].

The typical pattern for legacy compatibility, confirmed across multiple sources, is:

- Build a view named after the *legacy* table/columns, defined as a query against the *new* schema (joins, renames, casts as needed).
- Attach `INSTEAD OF INSERT/UPDATE/DELETE` triggers to that view that translate operations back onto the new tables.
- Legacy application code keeps issuing normal DML against what it thinks is its original table; it's actually writing to the new schema transparently[^10].

This is functionally identical to what pgroll and Reshape (below) automate — they just generate and manage these views/triggers for you rather than requiring hand-written DDL[^11][^12]. Your instinct that "this could get us pretty far" is validated by the fact that it's the literal implementation mechanism inside production-grade tooling.

The main risk noted in source material: unmanaged growth of trigger logic becomes an undocumented, untested second codebase. Several practitioners explicitly recommend logging usage inside the compatibility triggers so you know when the legacy path is actually dead and safe to drop[^10].

## Purpose-Built Tooling That Already Does This

Two open-source Postgres tools implement almost exactly the DSL + generated-DDL + dual-schema idea you're picturing, without needing Elixir/Ash:

| Tool | Mechanism | Migration definition | Rollback | Notes |
|---|---|---|---|---|
| **pgroll** (Xata) | Creates a new Postgres schema per migration containing views over the physical tables; both old and new schema versions are queryable simultaneously via `search_path` | Declarative JSON | Instant — drop the new schema/views | Captures DDL via event triggers; tracks full migration history in a `pgroll` metadata schema[^11][^13][^14] |
| **Reshape** | Similar view-based dual-schema exposure; uses triggers to upgrade/downgrade data between old and new representations during the transition | JSON/TOML migration files | Supported via two-step process | Requires a client-side helper to select the correct schema per connection[^12][^15][^16] |

Both tools operationalize your "produce and maintain the audit of all triggers and DDL" requirement: the migration definition is declarative, and the tool derives and manages the compatibility views/triggers, tracks version history, and exposes rollback as "just drop the newer virtual schema"[^11][^17]. pgroll additionally captures out-of-band DDL changes via event triggers so schema drift outside its own migrations is still recorded[^14].

For declarative, Terraform-style schema-diffing (less focused on live dual-schema serving, more on plan/apply of desired-state DDL), **pgschema** is a newer alternative worth evaluating alongside these[^18].

## CDC as the Alternative (and Often Complementary) Mechanism

Where writable views/triggers operate synchronously inside a single transaction against one physical schema, the other major strangler-fig data-sync mechanism is **Change Data Capture (CDC)**, typically via Debezium reading the Postgres WAL and publishing row-level change events to a stream (Kafka, etc.)[^19][^20][^21]. This decouples reads/writes on old and new schemas into two physically separate stores, which matters if "modern schema" really means a different service/database rather than just a cleaner table layout in the same Postgres instance.

Key trade-offs versus the trigger/view approach:

- CDC avoids in-transaction dual-write race conditions because the legacy DB remains the single synchronous writer; propagation to the new store is asynchronous[^19].
- It introduces eventual consistency and requires reconciliation jobs (checksum/row-count diffing) to catch drift — case-study data shows automated reconciliation raises migration success rates from roughly 34% (manual reconciliation) to 87%[^22].
- Cutover of write authority (deciding which side becomes the source of truth) is the highest-risk moment regardless of mechanism; idempotency keys and monotonic version numbers on rows are the standard mitigation[^19][^23].
- If both stores are Postgres and you're staying within one database, in-database views/triggers avoid CDC's operational overhead (Kafka, connectors, schema registry) entirely — CDC is more appropriate when the "modern schema" lives in a genuinely separate service/datastore[^20][^23].

Given your description — one Postgres database with two schemas — the trigger/view mechanism is almost certainly the leaner choice; CDC becomes relevant only if the strangler fig eventually extracts the modern schema into its own database or service.

## Mapping This to Ash/Elixir

There is no existing off-the-shelf Ash extension that implements "DSL defines mapping between two Ash resources, generates the compatibility DDL/triggers" — this appears to be a gap you'd be filling, not a known project. However, Ash's existing primitives are directly composable toward this:

- **`AshPostgres` polymorphic/context-based table routing**: Ash already supports a single resource being backed by different physical tables via `data_layer.table` context and `polymorphic? true`, with the migration generator inspecting all related resources to auto-generate the needed migrations[^24]. This is the closest existing analog to "one resource schema, multiple backing schemas" but it's designed for polymorphic associations, not legacy/modern dual-write — you'd need to extend the pattern rather than use it as-is.
- **Ash's declarative resource + DSL extension model** is exactly the right substrate for what you're picturing: define a `LegacyResource` and a `ModernResource`, then write a custom Ash DSL extension (a `Spark.Dsl.Extension`, the underlying DSL toolkit Ash itself is built on) that declares field-level and relationship-level mappings between them. A compiler/codegen step (similar to `mix ash.codegen` and `mix ash_postgres.generate_migrations`, which Ash already uses to diff resource definitions against migration state[^24]) could then emit the SQL views, `INSTEAD OF` triggers, and audit metadata table you described.
- **Ash's migration generator precedent** (diffing resource state to produce migrations automatically) is the strongest existing proof that "the DSL should drive the DDL, not the other way around" is idiomatic in this ecosystem — you'd essentially be writing a sibling code generator that emits compatibility-layer DDL instead of (or alongside) structural table migrations.
- For the audit trail, Ash's existing `AshPaperTrail`/resource change-tracking idioms (change hooks around actions) could log every legacy-vs-modern write path invocation, satisfying the "maintain an audit of all triggers" requirement at the application layer rather than purely in SQL logging.

No search result indicated this exact tool exists in the Ash ecosystem today, so building it would be original tooling — but architecturally it would sit squarely inside patterns the Ash core team has already established (DSL-driven resource definition → generated migrations/DDL).

## Recommended Approach

Given a single Postgres instance with legacy and modern schemas, the pragmatic sequence combines existing tooling with a thin custom layer rather than a full bespoke framework:

- Adopt **pgroll or Reshape** for the mechanical parts (view generation, `INSTEAD OF` trigger scaffolding, version tracking, rollback) rather than hand-rolling DDL generation — both already solve the "audit and maintain all triggers/DDL" problem you flagged[^11][^16].
- Layer an **Ash DSL extension** on top purely for the *mapping semantics* (field renames, type coercions, relationship reshaping) that these generic tools don't understand at the domain-model level, and use Ash's codegen conventions to keep it declarative and diffable[^24].
- Reserve **CDC (Debezium)** only if the modern schema will eventually live outside this Postgres instance; otherwise it adds unnecessary infrastructure for an intra-database migration[^20].
- Instrument every compatibility trigger with usage logging so you have empirical evidence of when the legacy write path is truly dead before the contract phase, per established practice[^10][^22].
- Track reconciliation automatically (row-count/checksum diffs) even in the trigger-based approach — case-study evidence shows this is the single highest-leverage investment for migration success regardless of sync mechanism[^22].

This sequencing gets you the "produce and maintain the DDL" outcome you're after while avoiding reinventing schema-version tracking and rollback machinery that pgroll/Reshape have already built and battle-tested[^11][^17][^16].

---

## References

1. [Parallel Change](https://martinfowler.com/bliki/ParallelChange.html) - Most database refactorings follow the parallel change pattern, where the migrate phase is the transi...

2. [Evolutionary Database Design](https://martinfowler.com/articles/evodb.html) - Many database refactorings, such as Introduce New Column, can be done without having to update all t...

3. [Zero-downtime database migrations: the expand-contract ...](https://matthewpalma.dev/blog/zero-downtime-database-migrations-expand-contract-pattern) - Ship relational schema changes without maintenance windows using expand-contract phases, backfills, ...

4. [Zero-Downtime Postgres Migrations: The Expand-Contract ...](https://agentscamp.com/guides/database/zero-downtime-postgres-migrations) - How to change a live Postgres schema without downtime or broken deploys — the expand-contract patter...

5. [Zero-Downtime PostgreSQL Migrations: A Battle-Tested ...](https://dev.to/tim_derzhavets/zero-downtime-postgresql-migrations-a-battle-tested-playbook-49ig) - Learn production-safe PostgreSQL migration patterns including lock management, expand-contract, and ...

6. [Database Migrations. The Expand-Contract Pattern](https://www.enolcasielles.com/en/blog/database-migrations-strategy) - In this article I share my experience on how I manage database migrations in high-availability envir...

7. [PostgreSQL Migrations Without Downtime: Expand, Migrate, Contract](https://adityatripathi.dev/blog/postgres-expand-contract-migrations/) - A field guide to backward-compatible schema changes, dual writes, and the patience required to delet...

8. [How we make database schema migrations safe and ...](https://www.getdefacto.com/article/database-schema-migrations) - Adopting the expand -> migrate -> contract migration pattern. Using PostgreSQL features to avoid bei...

9. [Documentation: 18: CREATE VIEW - PostgreSQL](https://www.postgresql.org/docs/current/sql-createview.html) - CREATE VIEW CREATE VIEW — define a new view Synopsis CREATE [ OR REPLACE ] [ TEMP | TEMPORARY ] …

10. [Triggers On Views? What For? - Michael J. Swart](https://michaeljswart.com/2012/10/triggers-on-views-what-for/) - What's up with triggers on views? What kind of patchwork monster is this?

11. [xataio/pgroll: PostgreSQL zero-downtime migrations made ...](https://github.com/xataio/pgroll) - pgroll is an open source command-line tool that offers safe and reversible schema migrations for Pos...

12. [pgroll vs reshape - compare differences and reviews?](https://www.libhunt.com/compare-pgroll-vs-reshape)

13. [pgroll 0.14 - New commands and more control over version schemas](https://pgroll.com/blog/pgroll-0-14-0-update) - pgroll 0.14 is released with several new subcommands and better control over how version schema are ...

14. [pgroll/docs/README.md at main · xataio/pgroll](https://github.com/xataio/pgroll/blob/main/docs/README.md) - PostgreSQL zero-downtime migrations made easy. Contribute to xataio/pgroll development by creating a...

15. [GitHub - fabianlindfors/reshape-helper: A Rust helper library for applications using Reshape](https://github.com/fabianlindfors/reshape-helper) - A Rust helper library for applications using Reshape - fabianlindfors/reshape-helper

16. [fabianlindfors/reshape: An easy-to-use, zero- ...](https://github.com/fabianlindfors/reshape) - Reshape is an easy-to-use, zero-downtime schema migration tool for Postgres. It automatically handle...

17. [Introducing pgroll: Zero-downtime, Reversible, Schema Migrations for Postgres](https://dev.to/xata/introducing-pgroll-zero-downtime-undoable-schema-migrations-for-postgres-5g30) - Schema migrations are painful Database schema migrations can be a double-edged sword. They...

18. [GitHub - pgschema/pgschema: Terraform-style, declarative schema migration for Postgres](https://github.com/pgschema/pgschema) - Terraform-style, declarative schema migration for Postgres - pgschema/pgschema

19. [Strangler Fig Pattern Implementation - Part 2](https://dev.to/kamal_namdeo/part-2-strangler-fig-pattern-implementation-31c7) - Strangler Fig Data Migration: Orders Service Extraction The core problem: two systems...

20. [Strangler Fig Pattern with Event Streaming](https://www.conduktor.io/glossary/strangler-fig-pattern-with-event-streaming) - Dual-write capability: Change Data Capture (CDC): Tools like Debezium can capture changes from legac...

21. [Resources on the Web](https://debezium.io/documentation/online-resources/) - Debezium is an open source distributed platform for change data capture. The Strangler Fig Pattern w...

22. [Strangler Fig Pattern: A Real Case Study with Metrics ...](https://softwaremodernizationservices.com/insights/strangler-fig-pattern-example/) - The Strangler Fig pattern gets sold as gradual, low-risk modernization. found 68% stalled before 90 ...

23. [Legacy Microservices Migration: Strangler Fig Guide](https://blog.tuttosemplice.com/en/legacy-to-microservices-migration-guide-to-the-strangler-fig-pattern-in-banking/) - Technical guide to legacy to microservices migration in the banking sector. Strangler Fig strategies...

24. [Polymorphic Resources — ash_postgres v2.6.17](https://hexdocs.pm/ash_postgres/polymorphic-resources.html)

