# ADR 0032 — Anonymization config is generated from the resource declarations

- **Status:** accepted (2026-11-17). Adopted: the generated config, its drift gate and a CI drill exist; no copy of a
  deployment we operate has been made yet
- **Date:** 2026-08-27
- **Implementation note:** 2026-11-17, at the end of this record

## Context

This repository answers *whose data is it* for the running application: attribute multitenancy on every
resource, a policy set inherited from the base, and an audit log that is itself tenant-scoped. It does
not answer the same question for the **copies**. Every environment that is not production runs one of
two things, and both fail:

**Seed data.** The demo tenant is hand-shaped and small, so the authorization model is exercised at the
scale of a screenshot. [Question 44](../roadmap.json) names the consequence — no load test, no query
budget, "a reference architecture that has never met a large tenant" — and every bug that only appears
at enterprise shape is found in production because nowhere else has the shape.

**Production data.** A tenant's data crossing into an environment with weaker controls — a developer
laptop, a CI runner, a staging instance with debug logging on — is a breach by definition, not a
configuration choice. It is also a new processing purpose under GDPR, which no amount of care inside
the pipeline cures afterwards.

[ADR 0024](0024-audit-retention-and-erasure.md) handles erasure *in place* — destroying a subject's
key in a database that stays production. That is a different problem from production *leaving*
production, and neither solves the other.

The structural fact this decision rests on: **the model already knows what is sensitive.** Ash
attributes carry `sensitive?: true`; the types are declared; the base resource already threads CDM
provenance, ownership and tenancy through every table. An anonymization config maintained by hand
beside that is a second copy of knowledge the model already owns — and it drifts permissively, because
the column someone forgets to list is exactly the column that passes through unmasked.

The candidate for the execution half is [greenmask](https://github.com/GreenmaskIO/greenmask)
(Greenmask, Inc.). Verified against its documentation and repository, 2026-08-27:

- **Apache-2.0**, stable line **v0.2.x** (v0.2.23, released 2026-08-22; the v1 line is currently a
  MySQL-only beta). Actively maintained — releases in six of the last seven months.
- Works over `pg_dump`'s directory format: schema via `pg_dump`/`pg_restore`, table data dumped and
  restored by greenmask itself over COPY connections. **Stateless** — no intermediate database, and the
  dump it produces is restorable by vanilla `pg_restore`. Tested against PostgreSQL 13–18.
- Declarative YAML: per-table transformers with parameters, validated by a `validate` command that
  performs a bounded test dump (`--rows-limit`, default 10) and emits constraint-aware warnings with
  severities — an `error` severity blocks the dump, `--strict` makes any unresolved warning exit
  non-zero, and `--schema` diffs the database against the previous dump, which exists precisely to
  catch "the schema changed and the config silently stopped covering it".
- **48 standard and 3 advanced transformers** (masking, noise, replace, regexp, template, cmd, and
  Faker-style generators), plus a `cmd` escape hatch that shells out to any program over
  stdin/stdout.
- Determinism — the property pseudoanonymization actually needs — is the documented job of the **hash
  engine**: SHA-3 with a `GREENMASK_GLOBAL_SALT`, *"the same input will always produce the same
  output"*, and two columns transformed with identical hash parameters are documented to receive
  identical values (their own example: `account.id` and `orders.account_id`). `apply_for_references`
  propagates a key transformation along foreign-key chains, including composite keys.
- It has **no sensitivity discovery at all**. It transforms exactly what the config names and nothing
  else.

That last bullet is the whole argument for the shape of this decision: the half greenmask does not
have — knowing which column holds a person — is the half Ash already has.

Alternatives, and why they lose:

- **A hand-maintained config.** The second-copy argument above. Greenmask's own validation cannot
  save it: `validate` checks that what the config *names* is well-formed, not that everything it
  *omits* is safe, because the tool has no way to know. A renamed attribute silently orphans its
  transform and the column passes through.
- **Masking inside the application** — a change or a hook that nulls sensitive fields on read. Wrong
  instrument twice over: a copy is produced from a dump, not through the action layer, so app-level
  masking never touches the artefact that leaves; and what an actor may *see* is already owned, in
  production, by field policies — using that machinery to define non-production copies would conflate
  *may you see* with *may this environment hold*.
- **A masked-data platform** (Tonic, neosync and the commercial category). Not evaluated to
  rejection on features — rejected on the structure [ADR 0021](0021-control-mapping-is-generated.md)
  already established for control maps: the platform's product is holding your sensitivity model in
  *its* UI, which is a second source of truth this repository refuses in every other dimension. The
  bar from [the roadmap](../ROADMAP.md) is a thin generated declaration handed to an external tool;
  a tool that insists on owning the declaration fails it.

## Decision

**A first-party extension, `ash_greenmask`, in the [`ash_api_versioning`](0019-api-versioning-as-presentation-contract.md)
shape: no new database objects, nothing running in the application. One DSL block on the resource
declaring how each attribute may leave production, and a generator that emits greenmask's YAML from
those declarations plus what the model already knows.** The design is written up in
[`../plans/ash-greenmask.md`](../plans/ash-greenmask.md); this record states the commitments the plan
must keep.

**1. The declaration lives on the resource, and inherits.** A `greenmask do … end` block names each
attribute's transformer; the defaults derive from what Ash already declares — `sensitive?: true`,
attribute type, the table mapping `ash_postgres` maintains. The block sits on the base resource where
the platform's other cross-cutting declarations sit, so [thesis 4](../manifesto/04-batteries-are-inherited.md)
applies: a new resource cannot quietly have no anonymization position, the same way it cannot quietly
have no audit.

**2. Generation is refuse-by-default.** A `sensitive?` attribute with no declared transform and no
explicit opt-out is a **generation error**, not a passthrough — the CDM generator's rule
("ownership is never guessed"), applied to disclosure. The opt-out exists and carries a mandatory
`because:` string, the same device [ADR 0008](0008-typed-invertible-legacy-mappings.md) uses for
uninvertible mappings: what is deliberately not covered is greppable, and the greppable thing is the
reviewable thing.

**3. The config is a derived artefact, and is gated like one.** `mix ash_greenmask.gen.config` emits
`greenmask.yml`; `--check` fails CI when it has drifted from the resource declarations, beside
`mix ash.codegen --check` and `mix ash_enterprise.roadmap --check`. Three drift gates in the same CI
run, for the same reason a derived artifact that *can* drift eventually will. The config contains no
secret — the salt is env-injected at greenmask runtime — and it names nothing the source it is
generated from does not already name.

**4. Consistency is the hash engine's job, and is declared once.** Referential continuity — the same
subject yielding the same pseudonym, foreign keys still resolving — comes from greenmask's hash
engine with an injected salt, plus `apply_for_references` for the key chains. The known caveat is
carried forward rather than absorbed: **the hash engine does not guarantee uniqueness**, so a hashed
primary key can collide; where that is unacceptable the declaration must say so, and the plan names
the check. The salt is load-bearing key material: SHA-3 is not reversible, but a *known* salt plus a
dictionary of candidate values re-identifies by brute force, so the salt obeys the same posture as
every other credential — injected at runtime, never at rest.

**5. The pipeline is the only door out of production.** The generated config, the dump, the
transformation and the restore happen in one CI job that never writes untransformed bytes anywhere it
does not have to (greenmask's own architecture is in-flight transformation for this reason). What is
*not* transformed is stated: greenmask's transformers target table data, and **large objects pass
through untransformed** — so either the dump excludes them or the generated config carries a named
residual saying it does not. An artefact that hides its own gaps is worse than one that declares
them, the same lesson [ADR 0012](0012-openlineage-and-marquez.md) draws about diagrams with omitted
edges.

## Does it consume ActorContext?

No — in either direction, and it must not. There is no actor at dump time; if there were,
authorization would be the wrong instrument, because a dump is a whole-database read and no actor is
entitled to one — which is exactly why the bytes must be transformed before anything person-like sees
them, rather than filtered by policy on the way out.

Greenmask clears the roadmap's bar structurally: it is handed a thin generated declaration, holds no
authorization model of its own, and never serves a query. The control that stands in for
ActorContext is **the pipeline itself** — the single path by which production data reaches a
non-production environment, and therefore the thing whose custody a customer's security
questionnaire is actually asking about. The residual runs the other way and is stated rather than
wrapped away: anyone able to run the pipeline can misconfigure it. Refuse-by-default generation is
the mitigation; a runtime check there cannot be, because there is no runtime.

## Consequences

**Made easy.** Realistic non-production environments become a build artefact rather than an incident
waiting for a reason: the demo tenant can be a transformed copy of a real one, and
[question 44](../roadmap.json)'s "seeded large tenant" gains an honest source. The SDLC harness this
platform is built inside — Coder workspaces and CI runners that need representative data to be
useful — gets a principled one. Sensitivity becomes one declaration with a drift gate, instead of a
document to remember. And because determinism is salted-hash-based, pseudonyms are stable within a
salt's scope while the mapping itself is worthless without the salt.

**Made hard.** Integrity requirements move from runtime — where Ash would enforce them on every read —
into a dump-time config where nothing re-checks them afterwards: a staging database whose foreign
keys were transformed inconsistently is *broken in a way its own queries will discover late*. The
greenmask pin is to the **0.2.x** line, whose `pg_bin_path` must match the server's major version, so
the pipeline carries a version coupling the application does not. The project is healthy but
concentrated — 413 of 567 commits by one author, 25 contributors — so the [ADR
0027](0027-feel-is-the-expression-language.md) posture applies: adopted, not written, with the
adoption isolated behind a generator so replacement is a config-emitter rewrite rather than a
platform migration. Hashing keys trades uniqueness guarantees away. And the salt becomes key material
an operator must manage per destination, where misuse is silent.

**Foreclosed.** In-place anonymization of the production database itself — that belongs to [ADR
0024](0024-audit-retention-and-erasure.md), and conflating the two would weaken both. Per-tenant
*visibility* policy — field policies already own that question, and a copy is not a policy
enforcement mechanism. And formal anonymity guarantees: what this produces is
**pseudo**anonymization — data that no longer names a person without additional information (the
salt) — and an ADR that claimed the stronger word would be claiming something no transform pipeline
delivers.

A hash-chained ledger table cannot be value-transformed without breaking its chain, so ledger tables stay out
of a dump until a policy for them is decided.

## Reversal

Cheap now, because nothing depends on it: no `ash_greenmask` line in `mix.exs`, no `greenmask` block
in any resource, no generated config in the tree. Abandoning the decision before adoption is a matter
of not adding any of the three.

*Note, 2026-11-08:* the package now exists and is public at `lukegalea/ash_greenmask`. *Note,
2026-11-17:* this app has adopted it (see the implementation note), so the sentence above no longer holds and the
paragraph below is the one that applies.

**To abandon after adoption:** delete the `greenmask do … end` blocks and the generated config with
the generator that produced it — both sides of the pair are deletable because neither is a
hand-maintained artefact anyone will be tempted to keep half of. Non-production environments fall
back to seeds, which is where they are today.

**To swap the engine:** the declarations are Ash-shaped and carry no greenmask vocabulary that a
transformer-name mapping table could not translate; the emitter is one module. This is the deliberate
shape — the same "behind a single adapter" defence [ADR 0028](0028-decisions-are-dmn.md) makes for
`boxic_dmn`, and for the same reason: a 0.x tool by a concentrated team is defensible exactly when
replacing it is measurable rather than speculative.

**The signal to watch:** if real resources keep needing transformers the closed mapping cannot
express — composite consistency beyond what salt and `apply_for_references` deliver, key types the
hash engine cannot target — then the thin-declaration premise is failing in practice, and the honest
response is a thicker declaration or a different tool, not an escaping tangle of `cmd` shims.

## Implementation note (2026-11-17)

Adopted. The platform base resource carries the `ash_greenmask` extension, 35 resources declare a `greenmask`
block, and [`greenmask.yml`](../../greenmask.yml) is generated from them and committed. Where the build differs from
the Decision:

- **Positions are declared per resource, not derived.** Commitment 1's defaults ("derive from `sensitive?`") are not
  built. What holds instead is the refusal: the base enables the block on every platform resource, and generation is
  strict (`config :ash_greenmask, strict?: true`), so a stored resource with a `sensitive?` attribute and no position
  fails `mix ash_greenmask.gen.config --check` in CI. A personal-looking column that is not `sensitive?` (the data
  inventory's name heuristic) is held by `greenmask_config_test.exs` instead: it must have a position too.
- **Ledgers are copied empty.** The audit log and its archive, the business-event ledger and its simulation twin and
  the compliance event log declare `exclude_data`: a value transform breaks a hash chain, and their JSON payloads hold
  values no column transform reaches. The config lists them under `exclude-table-data`.
- **Large objects are not copied.** The config sets `no-blobs`, rather than carrying a residual for them.
- **Keys are copied as they are.** The plan's open question (can the hash engine target `uuid` keys?) is answered:
  greenmask's `Hash` refuses a `uuid` column ("unsupported column type"), and `RandomUuid` with `engine: "hash"`
  targets one deterministically. The package's catalogue now carries `random_uuid`; no resource uses it, because a
  random key names no one. `apply_for_references` is not used.
- **The salt** is env-injected as decided. Where a deployment keeps it is the operator's, and
  [the runbook](../runbooks/production-copy.md) recommends a host-only secret file per destination.
- **The pipeline** is a drill, not a copy job. `scripts/greenmask-drill` runs in CI on the seeded database: it plants
  a sentinel in every transformed column, copies through greenmask v0.2.23 (pinned by sha256) and fails if one
  survives. It also has a read-only mode for a deployment's own database. Scoping a copy to one tenant
  (`subset_conds`) is not built.

What is still open: the drill has not run against a deployment we operate, so the claim stays at "the config and the
drill exist", and q55 is partial until it has.

