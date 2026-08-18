# ADR 0014 — Apache Superset over Metabase for BI

- **Status:** proposed
- **Date:** 2026-08-18

## Context

Once ingestion exists, someone asks for a chart. Reporting is a downstream need of every ingestion
pipeline and it deserves its own decision, because the wrong BI tool does not merely render badly — it
becomes a second place where "who may see this row" is decided.

[Thesis 7](../manifesto/07-what-we-do-not-have.md#8-reporting-and-document-generation) records entry 8:
`ash_typst` and `ash_reports` are early and lightly adopted, and pixel-controlled documents are bespoke
work. Nothing in the Ash ecosystem covers ad-hoc analysis and dashboards at all. The realistic choice is
an external BI tool over the same PostgreSQL instance, and in the self-hostable open-source category
that is Metabase or Apache Superset.

The temptation is to pick on ergonomics. Metabase is a single JAR, starts in a minute, and non-analysts
can use it unaided. Superset is a Python application needing a metadata database, Redis, Celery workers
and a Celery beat scheduler for async queries, alerts and thumbnails, plus a separate Node
`superset-websocket` service if `GLOBAL_ASYNC_QUERIES` is turned on (verified 2026-08-18 against
[the Superset architecture docs](https://superset.apache.org/admin-docs/installation/architecture/) and
`superset/config.py` on master). On operational cost alone Metabase wins outright.

**The licensing position is what decides it, and it is an architectural argument rather than a
preference.** All of the following was verified against primary sources on 2026-08-18:

- Metabase's repository is not cleanly AGPL. GitHub's licence detector reports `NOASSERTION`.
  `LICENSE.txt` states that source outside the top-level `enterprise` directory is AGPL and source
  inside it is under the Metabase Commercial License, "conditional on having a valid license from
  Metabase". A third file, `LICENSE-EMBEDDING.txt`, is a proprietary EULA covering `app-embed.js` that
  grants use "free and clear of any Affero GPL License requirements" and forbids "the removal of the
  Metabase's name or logo in the iframe".
- **Metabase's row-level security is a paid feature.** The docs say: *"Row and column security is only
  available on Pro and Enterprise plans (both self-hosted and on Metabase Cloud)."* The feature was
  formerly called data sandboxing and was renamed; searching for the old name returns nothing.
  ([docs](https://www.metabase.com/docs/latest/permissions/row-and-column-security)) Pro lists at
  $575/month, $517.50/month billed yearly.
- Custom appearance (white-labelling) and full-app embedding are likewise Pro-and-above.
- Latest Metabase as of 2026-08-18: v0.63.2 OSS / v1.63.2 EE, released 2026-07-29 from one code line.
- Apache Superset is Apache-2.0 (`LICENSE.txt`), an ASF top-level project with no vendor open-core
  edition and no commercial carve-out directory. Latest stable 6.1.0, released 2026-05-13; master had
  commits on 2026-08-18.
- **Superset's RLS is unconditional core behaviour.** The `ROW_LEVEL_SECURITY` feature flag no longer
  exists in `superset/config.py` — verified by reading master, not by reading documentation about it.

This repository's central claim is that authorization is data, evaluated as a pure union of grants
([thesis 3](../manifesto/03-authorization-is-data.md)). Adopting a BI tool whose row-level security is
behind a subscription would put that thesis behind a subscription for anyone who cloned the template.
That is not a budget question; it is the template failing at the thing it exists to demonstrate.

## Decision

**Apache Superset, connected to filtered PostgreSQL views (or a read replica of them) rather than to
base tables. Superset's own RLS configuration is a backstop, not the authorization system.**

The naive integration is to point Superset at the tables and reproduce the grant model as Superset RLS
clauses in Superset's admin UI. That is a second policy surface with its own storage, its own editing
workflow and its own drift — the exact anti-pattern
[thesis 3](../manifesto/03-authorization-is-data.md) is written against. It is also what makes the
Metabase paywall matter in the first place: a tool that owns authorization needs a licence for it.

So the filtering moves down into PostgreSQL, where both the application and Superset already are.
Superset can take a view as a dataset directly — its FAQ states that a datasource "can only be a single
table or a view" — so a generated, already-filtered view is an ordinary dataset with no special
handling.

Pushing the predicate into the database also closes a hole Superset actually has. `RLS_IN_SQLLAB`
defaults to `False`, and the config comment says so plainly: RLS is applied to SQL Lab queries only when
that flag is on. Out of the box, **any Superset user with SQL Lab access bypasses Superset RLS
entirely.** A predicate enforced by the database does not care which client wrote the query.

## Does it consume ActorContext?

Partly, and the gap is the main cost of this ADR.

`AshEnterprise.Security.ActorContext` is a BEAM struct built once per request and carried on the actor.
Superset does not make Ash requests; it opens a database connection. There is no way for a view to call
`ActorContext.for_actor/2`.

What *can* be consumed is the same source data. Every input the context resolves —
`Security.UserRole`, `Security.TeamRole`, `Security.RolePrivilege`, `Accounts.TeamMembership`, and
`Accounts.BusinessUnit.path` for subtree expansion — is already a PostgreSQL table, and the union in
`AshEnterprise.Security.Checks.RoleGrant` is already an `Ash.Policy.FilterCheck` producing an Ash
expression that AshPostgres renders to SQL. So the view predicate is derivable from the same
declaration the policy engine uses, rather than retyped.

**Derivable is not derived, and this is the honest part.** Nothing here generates those views today, and
hand-writing the union in SQL would create precisely the second copy this ADR rejects — one that drifts
silently, because a policy fix in Elixir does not touch a view definition. Building the generator means
rendering Ash expressions to parameter-free DDL, which
[ADR 0008](0008-typed-invertible-legacy-mappings.md) records as real work for a specific reason: AshSql
parameterises every literal and DDL cannot be parameterised, so literal escaping has to be built and
confined to one audited function. The same printer serves both, which is an argument for doing it once
rather than an argument that it is cheap.

Two further costs, stated rather than buried:

**Staleness.** A plain view has none, but pays the business-unit subtree expansion — the `path LIKE ANY`
prefix match in `ActorContext.load_subtrees/2` — on every query, which is the cost the context exists to
pay once per request instead of per row. A materialized view removes that cost and introduces a refresh
window in which a revoked role still grants access. A read replica adds replication lag on top. Every
one of those is a window where the BI tool is more permissive than the application, and the acceptable
width of that window is a decision this ADR does not make for you.

**Actor identity at the connection.** A view can only filter by actor if the connection carries one.
That means per-user database roles, or a session variable set on checkout, and either way Superset's
user directory has to agree with the application's. Superset's per-user database impersonation feature
is the obvious mechanism and is **unverified** here.

## Consequences

**Made easy.** Row-level security costs nothing and is not a licence tier. Dashboards, SQL Lab, alerts
and scheduled reports are all in the Apache-2.0 release. Superset datasets over generated views mean the
grant model has one editing surface — the `Security` tables — and the BI tool inherits changes rather
than mirroring them.

**Made hard.** Superset's operational footprint is genuinely larger than Metabase's: Python ≥ 3.11 on
master (6.1.0 still lists 3.10–3.12), a Postgres or MySQL metadata database, Redis, Celery workers and
beat. Superset's chart-authoring UX is also worse for non-analysts than Metabase's, and that cost lands
on the people this tool exists for. Superset queries a view of a query, so its own FAQ's warning
applies: performance is the base query's performance, and a wide view over a deep business-unit subtree
will be the thing that gets blamed.

**What this does not address.**
[Thesis 7 entry 6](../manifesto/07-what-we-do-not-have.md#6-analytics-and-warehouse-data-layers) is
untouched. There is still no Trino, Presto, Snowflake or BigQuery data layer for Ash, and Superset
connecting to a warehouse gives Ash nothing — the gap is Ash's reach into analytical stores, not the
dashboard on top.
[Entry 8](../manifesto/07-what-we-do-not-have.md#8-reporting-and-document-generation) is only partly
addressed: this covers ad-hoc analysis and dashboards and does not produce a pixel-controlled PDF
invoice or a regulatory filing. That half of entry 8 stays open and stays bespoke.

**Foreclosed.** Configuring row access in the BI tool. Once a Superset RLS clause is the authority for
any dataset, there are two grant models and the union is no longer pure.

## Reversal

Nothing is built: there is no Superset deployment, no generated views, and no dependency to remove.

**To choose Metabase instead:** the deciding fact is a purchase order. Metabase Pro at $517.50/month
billed yearly (2026-08-18) buys row and column security, and the view-generation work below becomes
optional rather than load-bearing. This is a defensible choice for a company; it is not a defensible
default for a template, which is the whole of the disagreement.

**To abandon the generated-view approach but keep Superset:** delete the views and configure Superset
RLS clauses per dataset in its admin UI. One afternoon, and it costs the single-source-of-truth
property — plus it requires denying SQL Lab to every user who is not trusted with the whole database,
because `RLS_IN_SQLLAB` defaults off.

**To abandon Superset entirely:** drop the deployment and the views. Nothing in `lib/` imports it and
nothing in `mix.exs` references it — the seam is that Superset reads the database and never the
application, which is what
[thesis 6](../manifesto/06-reversibility.md) asks of anything outside tier 1. Removal is a deletion.

**The signal to revisit:** Superset's RLS moving behind a flag or a vendor gate, or Metabase moving row
and column security into the free edition. Both are licence changes rather than technical ones, which is
why the dates on every claim above are load-bearing.
