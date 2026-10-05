# NL search → editable filter proposal: the Basic CQL2 slice

**Ticket:** S1-65 ("NL search as an editable filter proposal — the Basic
CQL2 slice"). **Mechanism:** `AshEnterprise.SystemOne.FilterProposal`,
`AshEnterprise.SystemOne.FilterExecution`, and the
`AshEnterprise.SystemOne.Filter.*` cluster.
**Doctrine:** S1-56 §3 (the search IS the filter; model output never
executes unedited; no silent filters), S1-57 §4–§6 (Basic CQL2-JSON as
the API surface, three-valued pins, scope binds at request time), ADR
0046 (the declaration is the output contract), ADR 0048 (a judgment is a
predicate over any set; authorization is unchanged).

---

## The story in one paragraph

Someone types a search in plain English. An in-zone generative instrument
(`:winnow_generative`, the S1-61 transport) translates it into a candidate
**Basic CQL2-JSON** document, decoded under a wire schema DERIVED from the
declared queryables of the facts surface — property names outside the
declared vocabulary cannot even decode. What lands is an **editable,
versioned proposal**: a person edits the document (each edit is a new
version, re-validated, predecessor superseded, chain always visible),
approves it as a person, and only then can it run — explicitly, never
automatically. The run compiles the approved document deterministically
and reads the facts surface as the actor, through the facts surface's own
policies: the model is never in the read path, and a judged predicate
never widens what the actor may see. Results come back as three
partitions with counts — `in`, `out`, and `unknown` — and the unknown
partition is returned as data, never folded away, because it is the
assess action's input. Every run writes an audit row: the final
(post-edit) document, the compiled plan, the partition counts, and the
link back to the translation observation that seeded the chain.

## The pipeline

```
NL search text ──▶ :winnow_generative (recorded instrument call) ──▶ decode under
the derived wire schema ──▶ typed pass ──▶ FilterProposal (status: proposed)
                                            │
                  person edits ─▶ new version (re-validated, predecessor superseded)
                                            │
                  person approves ◀─────────┘   (or rejects)
                            │
                  Filter.Runner.run (explicit; refuses anything unapproved)
                            │
        Ash read of Fact (:current, as the actor, through policies)
                            │
        Compiler.fold ─▶ in / out / unknown, with counts
                            │
        FilterExecution (final document + compiled plan + seed digests)
```

## The Basic profile, as implemented

Exactly the ticket's operator set — scope discipline over completeness:

- **Logical:** `and`, `or` (Kleene: false dominates `and`, true dominates
  `or`, unknown otherwise).
- **Comparison:** `=` `<>` `<` `<=` `>` `>=` — property ↔ literal only;
  property–property comparisons (CQL2 §7.10) are refused as outside the
  Basic slice. Equality is strict and non-coercing (`80 ≠ 80.0`, the IR's
  own discipline).
- **`in`** — non-empty, homogeneous, property-typed list. Local pin
  (the OGC text is silent): an unknown left operand evaluates unknown.
- **`isNull`** — the unknown partition's native spelling.
- **Status clauses** — every judged predicate additionally exposes
  `<question_id>.status` with the frozen interchange enum
  `admitted_true | admitted_false | review | not_assessed | stale`
  (S1-57 §6). The fold never *produces* `review` — an open review task
  reads as `not_assessed` because the materialiser writes no fact for a
  review — but the word stays in the enum so exported documents and peer
  systems share one vocabulary. Status fields are **total** (never
  unknown): `isNull` on a status field is always false, and
  `not_assessed` IS the unknown partition's explicit spelling.

Deliberately NOT in this slice (follow-up tickets): `not`, `like`,
`between`, spatial/temporal/array classes, property–property comparison,
arithmetic, functions, date/timestamp literal types.

## Declared queryables: the vocabulary is a declaration, never discovery

`AshEnterprise.SystemOne.Filter.Queryables` is the single host-owned
place where the facts surface's filterable vocabulary is declared:

- **Judged predicates** — every question declared on the configured
  subject resources (`config :ash_enterprise, :system_one_subject_resources`),
  named by its exact `question_id` (the predicate spelling a judged fact
  carries). Answer type fixes the CQL2 scalar type: Noul → boolean,
  Choice → string with the declared option words (abstention included,
  law 7), Score → integer. Extraction-typed questions are refused at this
  surface (composite values are not Basic scalars).
- **Crisp attributes** — the host's fact-schema entries for directly
  entered facts. The v0 slice declares a small synthetic demo schema
  (`city`, `licence_current`, `revenue`, `hourly_rate`); a real crisp
  schema replaces the list without touching anything downstream, because
  every consumer derives from this module.
- **Derived status fields** — one per judged predicate, as above.

The wire JSON Schema (`Filter.Schema`) is **derived at call time** from
this vocabulary — unlike the question proposal's static schema file,
because the whole point is the restriction: the property-name enum *is*
the declaration (ADR 0046's mechanism with a moving contract). The typed
pass (`Filter.Document`) finishes what JSON Schema cannot say across
positions: per-operator arity, property↔literal type agreement, enum
membership, ordering on numeric properties only.

## The three-valued pins (S1-57 §6, verbatim)

- The unknown partition is queried explicitly: `isNull` on the property,
  or a `.status` clause. Absence never silently means false.
- Absence semantics travel with the fact schema: judged properties are
  fixed to unknown-on-absence by this profile; the filter document cannot
  say otherwise.
- Scope binds at request time: filter documents are scope-free; the run
  takes `:scope` (exact match) as a parameter.
- The minimum admission grade is a request-time consumer parameter
  (Q19): `:min_grade` (default `:grant`) narrows the read.

## Boundary: where the partitions come from

The facts surface is a row-per-fact table with no subject registry, so
the three partitions are over **subjects present in the facts surface**:
a subject with no facts at all is not in the surface, while a subject
with any actor-visible current fact is folded (and lands in `unknown`
when the document references predicates it lacks). The read is one
`Ash.Query.for_read(:current, ...)` as the actor; the fold is pure.
Scaling past the homelab (pushing the fold into SQL per subject type,
or deriving a subject surface per declaration) is a v1 concern, not a
correctness one.

## The gates, in order

1. **Decode gate.** Undecodable or schema-invalid model output is a
   **refused** proposal with the raw output retained verbatim — never a
   best-effort parse. A failed translation opens nothing.
2. **Edit gate.** Only a person edits; each edit re-runs the full decode
   contract and mints a new version (same root, predecessor superseded)
   in one transaction. A failed re-validation writes nothing.
3. **Approval gate.** Only a person approves (`Checks.PersonActor` — a
   system actor, the `ai` label, or anything without a user row fails).
   Approval executes nothing.
4. **Run gate.** `Filter.Runner.run/2` refuses anything whose status is
   not `:approved`, and re-checks the queryables digest: a declaration
   change between edit and run is a refusal, never a drift. The run is
   always an explicit call; there is no auto-run path.
5. **Visibility.** The facts read goes through `AshEnterprise.SystemOne.Fact`'s
   policies as the caller — a judged predicate is never a row-access
   policy, and the fold only ever sees rows the actor's read returned.

## Audit (S1-56 §3.5)

Every executed query writes `FilterExecution` on the platform base
(AshEvents-audited, tenant- and correlation-attributed): the final
post-edit CQL2 document exactly as executed, the compiled plan
(strategy, referenced predicates, operators, request-time scope and
grade floor), the three-partition counts, and the seed links — the
proposal version, the translation observation's wire question hash, and
the NL digest. The NL text itself stays on the (payload-class) proposal
and never lands on the execution.

## Test map

`test/ash_enterprise/system_one/filter_proposal_test.exs` — decode
success and every refusal path (not-JSON, wrong operator, ghost
property, type mismatch; raw always retained), the versioned edit path,
the person-approval gate, never-auto-run.

`test/ash_enterprise/system_one/filter_run_test.exs` — compile truth
tables per operator including the three-valued rows and the status
clauses, three-partition correctness cross-checked against the facts the
package's materialiser wrote, the run-level approval gate, min-grade and
scope as request-time parameters, visibility narrowing for a grantless
actor, vocabulary-drift refusal, and the audit rows.
