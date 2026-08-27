# AshGreenmask — pseudoanonymization derived from the resource model

> **PROPOSED — nothing here is built.** This document exists so the design questions get answered on
> paper first, where they are cheap. [ADR 0032](../adr/0032-anonymization-config-is-generated.md)
> records the decision this plan specifies. Like
> [`ash-api-versioning.md`](ash-api-versioning.md), it should be re-tested against an implementation
> rather than trusted — and, following this directory's convention, corrected by appending dated
> sections rather than by editing the body quietly.

## 1. The situation

Every environment that is not production runs one of two things.

**Seed data** is safe and useless at the only moments that matter. A hand-shaped demo tenant cannot
exercise the authorization model at enterprise shape, cannot surface the query that returns forty
thousand rows, and cannot reproduce the bug that only appears with real dirt under its fingernails —
real data is dirty in ways no seeder imagines, and the dirt is the payload. [Question
44](../roadmap.json) already names what the absence costs.

**Production data** is representative and unacceptable. A tenant's records on a developer laptop, in
a CI runner, or on a staging instance with debug logging enabled is a breach by definition, and under
GDPR it is a new processing purpose — a disclosure the platform has not made and cannot make
retroactively. The gap between these two failure modes is not bridged by discipline. Developers who
cannot get representative data safely get it unsafely, eventually, at 2am, with a ticket open.

What is needed is a third thing: a **copy of production that has stopped being production data** —
same shape, same dirt, same row counts, no persons. That is a pipeline, not a feature: dump,
transform, restore. The only interesting question is where the *knowledge of what to transform*
lives. This plan's answer: in the resource model, where it already is.

## 2. What the model already knows

Ash resources declare, per attribute:

- **Sensitivity** — Ash's own `sensitive?: true` flag, already respected by logs and introspection.
- **Type** — `Ash.Type` carries the constraints (`uuid`, `:string` with length, `:decimal` precision),
  which is exactly the information a transformer needs to stay type-safe.
- **Table and column** — `ash_postgres` maintains the resource→table, attribute→column mapping,
  including embedded and multitenancy attributes.
- **Relationships** — the foreign-key graph, which is what consistent pseudoanonymization has to
  preserve if the copy is to join the way the original does.
- **Provenance and tenancy** — the base resource threads CDM provenance and `organization_id` scope
  through everything, so "which tenant's data is this column even about" is answerable, not guessed.

greenmask, verified 2026-08-27 (see [ADR 0032](../adr/0032-anonymization-config-is-generated.md) for
the fact list), is a stateless transformer over `pg_dump`'s directory format with 51 transformers, a
constraint-aware `validate` mode, and a deterministic hash engine — and it has **no sensitivity
discovery whatsoever**. It transforms exactly what its YAML names. The complementarity is exact: the
half it lacks is the half Ash has. The extension's entire job is standing between the two.

## 3. The DSL

One block on the resource:

```elixir
greenmask do
  # One transform per attribute that may leave production transformed.
  transform :email, :random_email
  transform :phone, :masking, replacement: "$1*****$2", terminator_length: 0
  transform :full_name, :cmd, program: "name-shaper", driver: :json

  # Deterministic, referentially continuous by default (see §4).
  transform :id, :hash, apply_for_references: true

  # Explicit, reviewable opt-out. `because:` is mandatory and lands in the
  # generated config's header comment, verbatim.
  keep :organization_id, because: "tenant key; a copy without it cannot be scoped"
end
```

Semantics, in order of importance:

1. **`transform` names an attribute, not a column.** The generator resolves through `ash_postgres`
   to the physical column. A renamed attribute re-resolves; a renamed *column* without a resource
   change is not a thing that can happen here, because migrations are derived from resource
   snapshots ([question 27](../roadmap.json)) — the same invariant, pointed the other way.
2. **`keep` is the only way through unchanged, and it says why.** The `because:` string is the device
   [ADR 0008](../adr/0008-typed-invertible-legacy-mappings.md) uses for non-invertible mappings:
   what is deliberately uncovered is greppable, and the greppable thing is the reviewable thing.
3. **Refuse-by-default.** Generation fails when: a `sensitive?` attribute has neither `transform` nor
   `keep`; a transformer name is not in the closed mapping (§5); a type cannot carry the named
   transformer (`:noise` on `:string`, and so on). The error names the resource, the attribute, and
   the reason — the same refusal shape the CDM generator established ("ownership is never guessed").
4. **Inheritance from the base resource.** `AshEnterprise.Platform.Resource` declares the platform's
   defaults once — audit metadata keys hashed, timestamps kept with `because: "shape, not person"` —
   so a new resource arrives with a position rather than a hole. This is [thesis
   4](../manifesto/04-batteries-are-inherited.md) applied to disclosure: the battery is "cannot
   accidentally leak", inherited.
5. **No database objects, no runtime.** The block compiles to Spark metadata and nothing else. No
   migration, no trigger, no code path in the running application. This is what makes the extension
   categorically cheaper than `ash_strangler` and keeps it on the `ash_api_versioning` side of [ADR
   0019](../adr/0019-api-versioning-as-presentation-contract.md)'s line: lose this property and the
   tool is the wrong shape.

## 4. Determinism, consistency, and the salt

Pseudoanonymization lives or dies on **referential continuity**: if `users.id` and
`audit_events.actor_id` name the same person in production, their transforms must name the same
pseudonym in the copy, or the database that comes out is not queryable in any way that matters.

greenmask's documented mechanism is the **hash engine**: SHA-3 with a `GREENMASK_GLOBAL_SALT`, "the
same input will always produce the same output", with identical parameters on two columns documented
to produce identical values — their own worked example is `account.id` and `orders.account_id`.
`apply_for_references` propagates a key's transformation along the foreign-key chains that reference
it, composite keys included. The DSL's `:hash` default for keys maps onto exactly this; the extension
does not build a second consistency mechanism beside greenmask's, because a second mechanism is a
second thing to diverge.

Two caveats are load-bearing and belong in the plan rather than in a footnote:

- **The hash engine does not guarantee uniqueness.** A hashed primary key can collide. The generated
  config therefore carries a per-transformed-key assertion in the `validate` phase, and the plan's
  test story (§6) includes a restore-time foreign-key integrity check. Where a collision is
  unacceptable the declaration must choose a unique generator instead — accepting that generated keys
  are *not* referentially continuous, which is a trade the declaration makes visibly rather than one
  the tool makes silently.
- **The salt is key material.** SHA-3 is not reversible, but a known salt plus a dictionary of
  candidate values re-identifies by brute force. So the salt obeys the platform's credential posture:
  env-injected at greenmask runtime, never in the repo, never in CI logs.

**Salt scope is a real choice with a real trade, made per destination rather than globally:**

- *One salt per destination environment* (the default this plan proposes): two staging restores
  cannot be joined to re-identify across them — cross-environment linkage is structurally impossible,
  not merely discouraged. The cost: yesterday's transformed copy and today's cannot be diffed row by
  row, because the same person maps differently.
- *One global salt*: copies are mutually consistent, and mutually re-identifying. Any one
  environment's copy becomes a dictionary against all the others.

The default is the one that fails closed, consistent with how this platform treats every other
boundary.

## 5. The closed transformer mapping

The extension exposes a **closed, curated mapping** from DSL names to greenmask transformers — not
greenmask's full catalogue. Rationale: the mapping is the compatibility surface that makes engine
swap measurable ([ADR 0032](../adr/0032-anonymization-config-is-generated.md), Reversal), and a
surface of 51 entries is a surface nobody audits.

Proposed initial set — masking, replace, regexp_replace, set_null, noise (numeric/date), random
generators (the Faker family greenmask ships), hash, dict, template, and `cmd` as the escape hatch
with its own warning in the generated header (greenmask's own security guidance: the `cmd`
transformer executes arbitrary commands). Types are part of the mapping: each entry declares the Ash
types it can target, and a mismatch is a refusal (§3.3).

## 6. Generation, gates, and the pipeline

```
resource declarations ──▶ mix ash_greenmask.gen.config ──▶ greenmask.yml (committed)
                                      │
                                      └── --check: CI fails if the YAML has drifted
                                          from the declarations

greenmask.yml + salt (env) ──▶ greenmask dump (validate --strict) ──▶ transformed dump ──▶ restore
```

- **The generated config is committed and gated.** This follows the repository's established
  pattern — `resource_snapshots/`, the roadmap tables — rather than inventing a new posture: derived
  artefacts are committed *so that* CI can prove they have not drifted. The YAML contains no secret;
  the salt arrives by environment at runtime.
- **`greenmask validate --strict` runs in CI against the CI database**, before any dump touches real
  data: it performs a bounded test dump (default 10 rows per table), emits constraint-aware warnings
  at graded severities, and under `--strict` any unresolved warning fails the job. Its `--schema`
  diff — database against the previous dump — is the exact shape of "the schema changed and the
  config silently stopped covering it", caught by the tool built to catch it.
- **The pipeline runs where the custody is provable** — one CI job, no intermediate storage of
  untransformed bytes (greenmask's architecture is in-flight transformation; its storage stages hold
  the transformed dump), destination credentials injected, everything attributable the way every
  other state change in this platform is.

The **test story for the extension itself**, when it is built: same-row-same-pseudonym properties
across two runs under one salt; a restore whose foreign keys all resolve; and the generator's own
invariant — every `sensitive?` attribute of every resource is covered by `transform` or `keep`, which
is the assertion that makes refuse-by-default a property rather than a promise.

## 7. Residuals, stated rather than hidden

- **Large objects pass through untransformed** (greenmask's transformers target table data). The
  generated config's header says so, and the dump excludes them by default; keeping them is an
  explicit pipeline option that also carries the warning.
- **Quasi-identifiers.** `keep :postal_code` and `keep :date_of_birth` are individually defensible
  and jointly identifying; k-anonymity is not attempted and not claimed. The residuals manifest the
  generator emits (what passed through, and why) is the artefact a reviewer uses to make this call
  with eyes open.
- **Pseudo-, not anonymity.** The output names no person *without the salt* — that is the definition
  the ADR commits to, and the salt's custody is what the claim rests on. Formal differential privacy
  is not claimed; greenmask's `noise` transformers are statistical noise, nothing more.
- **The destination's own hygiene** is out of scope and stays so: a staging environment with the same
  hardening as production is a deployment requirement, not a property the dump can carry.

## 8. Open questions

These are the questions most likely to change the design when they meet an implementation, written
down so the change is visible:

1. **Can the hash engine target `uuid`-typed keys at all?** The docs claim driver-level type safety,
   but a SHA-3 digest is not a UUID, and whether greenmask encodes it into the column type or refuses
   is **undetermined from documentation** — it must be settled by running `validate` against a real
   schema. If it refuses, deterministic keys need a derived mapping (for example, UUIDv5 over the
   hash) through the `cmd` transformer, which is exactly the kind of shim §5 exists to make a
   visible, reviewable exception rather than an ambient habit.
2. **Sequences.** Auto-increment sequences restore differently from transformed keys; whether the
   copy's sequences need resyncing post-restore is a pipeline detail the first real restore will
   answer.
3. **Subsetting for demo copies.** greenmask's `subset_conds` can scope a copy ("one organization,
   ninety days") — attractive for seeded demos, and worth declaring in the DSL only if the first
   three copies want it. Until then it stays a config-level capability, not a DSL commitment.
4. **Multitenancy of the destination.** Should a copy ever carry *all* tenants, or is
   one-tenant-per-copy the stronger default? Leans one-tenant-per-copy for the same reason the salt
   decision does: it is the option that fails closed.
5. **Where the pipeline lives in the SDLC harness.** The harness (Coder workspaces, CI runners) is
   the first consumer this design is aimed at; whether the dump job is one pipeline or a per-
   environment fan-out is a harness-side decision this plan should inform, not make.

## 9. What would disprove this plan

- Real resources needing transformers outside the closed mapping repeatedly — the thin-declaration
  premise failing, per [ADR 0032](../adr/0032-anonymization-config-is-generated.md)'s own reversal
  signal.
- `validate` proving unable to catch a class of constraint violation the copy then exhibits — which
  would move integrity checking into the restore path, changing the pipeline's shape.
- The uuid question (§8.1) resolving to "not supportable without shims everywhere" — which would
  push key transforms off the hash engine and toward a pre-computed mapping table the extension has
  to own, a materially bigger surface.

## 10. Status

**Nothing here is built.** No `ash_greenmask` package exists, no `greenmask` block sits on any
resource, no generated config is committed. What exists is this plan,
[ADR 0032](../adr/0032-anonymization-config-is-generated.md), and a repository reserved to hold the
extension when it is written ([`lukegalea/ash_greenmask`](https://github.com/lukegalea/ash_greenmask)).
When any of that changes, this section says so, with a date — and the corrections arrive as appended,
dated sections rather than as quiet edits to the text above.
