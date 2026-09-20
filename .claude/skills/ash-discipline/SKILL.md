---
name: ash-discipline
description: "Use when writing or reviewing ANY Elixir code that touches Ash resources — domain code, workers, projectors, mix tasks, generated code, or tests. Enforces the anti-raw-SQL rule, code-interface discipline, actor/tenant conventions, and the Ash action lifecycle. Non-negotiable project standard distilled from ScribbleVet production conventions and official Ash 3.x guides."
---

# Ash discipline: the enforced standard

## The one rule that catches most violations

**Domain reads, writes, and business queries never use raw SQL.** `Repo.query/3`,
`Repo.all/2`, `Ecto.Adapters.SQL`, or hand-written `SELECT/UPDATE/DELETE` against
Ash-backed tables in domain code is a defect, not a style choice. Raw SQL silently
bypasses policies (filter-mode read policies are an anti-enumeration security
feature), multitenancy filters, field policies, validations, and
calculation/aggregate pushdown.

### Where raw SQL IS acceptable — each occurrence needs a written justification comment

1. **Mix tasks / ops tooling** — backfills, benchmarks, one-off scripts.
2. **DDL generation by data-layer extensions** — when the package's product IS
   SQL (e.g. ash_strangler's view/trigger/ledger rendering).
3. **Dedicated, named infrastructure modules for SQL-only features** against
   **non-Ash tables** — `SKIP LOCKED` queues, `pg_notify`/`LISTEN`, advisory
   locks, health probes. Bridge results back into Ash (hydrate via
   `Ash.Query.filter(id in ^ids)`).
4. **Measured performance escapes** — must re-enter Ash for hydration, with the
   measurement that justified it.

Everything else: use a code interface, a named read action, `Ash.Query`
composition, calculations/aggregates, or bulk actions. `fragment/2` inside
`expr(...)` is the sanctioned in-framework SQL escape.

## Code interfaces

- Every repeatedly-called action gets a `define` on the domain (or
  `code_interface` on the resource) — `get_by:` for single fetches, positional
  `args:` for values callers must not set via form params.
- "No API layer" means no *wire* exposure (no AshJsonApi/AshGraphql) — it does
  NOT mean omitting code interfaces. Internal and host callers use interfaces,
  not `Ash.create!/read!/get!`.
- Callers pass `actor:`/`tenant:`/`authorize?:` in options; prefer the raising
  `!` variants; the extra-inputs map beats optional args.
- No `Ash.get!/Ash.load!` in LiveViews/Controllers — `get_by` interfaces with
  `load:` options.

## Where logic lives

- Business logic inside actions as changes/validations/preparations — named
  modules (`Ash.Resource.Change` etc.), never anonymous functions for
  non-trivial logic.
- Business queries are named read actions on the resource (e.g. waiver-validity
  filtering is `read :valid_at` with a `:now` argument — not an inline
  `Ash.Query.filter` pipeline in the caller). The helper built outside the
  resource "is meant to be obsoleted by your Ash resource".
- Lifecycle: external calls in `before_transaction`/`after_transaction`;
  DB-dependent writes in `after_action`; `require_atomic? false` only with
  written justification.

## Actors, tenancy, queries

- Actor is set on the subject (`Ash.Query.for_read(..., actor: user)`), not on
  the `Ash.read!` call.
- `authorize?: false` only in trusted contexts (workers, projectors, factories)
  and paired with `actor:` when attribution matters. Never on security-critical
  reads. Host-facing library functions must thread optional `actor:`/`authorize?:`
  through rather than hard-coding the bypass.
- Tenancy via `tenant:` option / multitenancy DSL — not hand-rolled
  `organization_id` filters repeated at each call site.
- `require Ash.Query` wherever `filter/2` is used. Derived data =
  calculations/aggregates/`exists/2`, never hand-joins.
- No `String.to_atom/1` on event/payload-derived binaries — validate against
  known atoms.

## Tests

- Through code interfaces with `authorize?: false` when auth isn't under test;
  policies tested separately via `can_*?` and negative
  `{:error, %Ash.Error.Forbidden{}}` assertions.
- Globally unique identity values in concurrent tests (deadlock rule).

## Review trigger

When reviewing generated code (codegen tasks, worker templates): check the
rendered output compiles against the HOST's aliases (an unqualified `Repo.` in a
rendered template is a shipped runtime bug), and that every raw-SQL line in the
template carries its justification.

Sources: `/home/lukegalea/ScribbleVet/api` production conventions (.clawish/CONVENTIONS.md),
Ash 3.x guides (actions, code-interfaces, policies, multitenancy, testing).
