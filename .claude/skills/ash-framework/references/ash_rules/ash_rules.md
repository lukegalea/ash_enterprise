# ash_rules usage rules

_Rules for working with the ash_rules library, for humans and agents alike._

## What this package is, and is not

A pure rule-engine Spark DSL. `use AshRules` gives a module a `fact_schema` and
top-level `rule` declarations that compile into an immutable, content-hashed
`AshRules.Ir.Bundle`; `AshRules.evaluate/3` gives verdicts back. Bundles in,
verdicts out. There is no storage, no web layer, no supervision tree, no
notifications and no persistence of results — the package's `application` is
empty on purpose (`mix.exs`: `extra_applications: [:logger, :crypto]` only, the
`:crypto` is the SHA-256 content hash). Projecting results into host state is
`ash_compliance`'s job. If a change adds I/O to evaluation, it is in the wrong
package.

## The architectural line

> **Missing data is never a pass — and never silently a violation.**

Every fact declares what absence means (`:false`, `:unknown`, `:no_fact`), and
`missing: :unknown` facts make probing rules `:unknown`, which never collapses
to `compliant`. Do not work around this by feeding placeholder facts to make a
rule evaluate; fix the schema's absence semantics or fix the pipeline that
should have supplied the fact.

## Rules

1. **Rules are data, not code.** A rule set compiles to a content-hashed
   `AshRules.Ir.Bundle`. Never persist quoted AST, never `Code.eval` rule
   content, never round-trip rules through Elixir terms when the wire format
   is what you mean. Tenant rules arrive as decoded JSON and pass the same
   verifiers as DSL-authored ones (`AshRules.Ir.decode/1` reuses the DSL's
   verifiers — unknown predicates, type mismatches, unbound variables, missing
   outcome/severity/gap; a refusal is a refusal no matter which door the rules
   came through).
2. **Validate before activation, never at evaluation.** Compile-time
   verification is the product: a rule that reaches production with an
   unbound variable has defeated the entire design. When adding rule
   features, add the verifier and its negative test in the same change.
3. **Declare the combining algorithm knowingly; default is `deny_overrides`.**
   `combining/1` accepts the four XACML-derived algorithms —
   `deny_overrides` (default; worst applicable outcome wins),
   `permit_overrides`, `first_applicable`, `only_one_applicable`. Under
   `only_one_applicable`, two applicable rules are `:error` by design: two
   rules claiming sole jurisdiction is a misconfiguration, not a tie to break.
4. **Type every fact, and declare absence on purpose.** `fact_schema` entries
   are `fact :name, :type` with `one_of:` closing an `:atom` fact's
   vocabulary. The `missing:` option is the integrator's trap — three
   semantics, one default:
   * `false` (the default) — absence counts as the value `false`, *and the
     absence is reported* in the result's missing facts;
   * `:unknown` — absence makes every rule probing the fact `:unknown`,
     never silently false;
   * `:no_fact` — absence is an expected, meaningful state: probes behave
     like `false`, and nothing is reported.
   "We have no data" and "we know it is false" are different answers; the
   auditor reads the difference in `missing_facts`. Declare `missing:
   :unknown` whenever a probe decides compliance.
5. **Every rule carries an id, a severity, and — if it can fire
   `:noncompliant` — a gap.** `rule "statement", id: ..., severity: ...` with
   `when_requires has(subject, predicate, value)` applicability triples,
   `fails_when neg(...)` failure conditions, and `outcome :noncompliant, gap:
   "..."`. The verifiers refuse an id-less or severity-less rule, and refuse
   a `:noncompliant` outcome without a gap — the unfiled finding is the one
   that cannot be waived, tracked or aggregated. `neg/3` cannot introduce
   variables (absence cannot bind); `%{variable}` message placeholders render
   from the match bindings.
6. **Equality is strict, with no numeric coercion.** `AshRules.Ir.values_equal?/2`
   is `===`: a rule that says `80` does not match a fact that says `80.0`.
   Declare the fact type the producer actually writes.
7. **Facts are `{subject, predicate, value}` triples, and the subject is
   opaque.** The predicate must be an atom declared in the bundle's fact
   schema and the value must type-check — both refusals name the fact and the
   fix. But the *subject* travels through the wire untouched: encode a bundle
   whose DSL says `has(:customer, ...)` and the JSON carries `"customer"`;
   decode it and the probe's subject is the *string*. Strict equality means a
   fact emitted as `{:customer, :status, :active}` never matches a decoded
   bundle's `"customer"` probes. When a bundle has crossed `encode!/decode`
   — any bundle that went through a control plane did — emit facts in the
   post-compile spelling (string subjects). This exact mismatch is the trap
   the clinic-demo guard's `@subject "appointment"` comment documents.
8. **Read `overall` first.** `AshRules.evaluate/3` (module or bundle, facts,
   opts `:evaluator`/`:seed`) returns `{:ok, %AshRules.Result{}}` whose fields
   are the audit report: `overall`, per-rule `requirements` (outcome, gap,
   message, bindings, consumed/probed/missing facts), `derived_facts`,
   `missing_facts`, `bundle_hash`, both revisions, the combining algorithm and
   the seed. `AshRules.Result.findings/1` lists the fired requirements.
   `:unknown` and `:error` never collapse to `:compliant` — the property
   suite asserts it (`AshRules.Outcome.blocking?/1` names the two).
9. **Hosts block on the three bad outcomes.** A caller gating an action on a
   verdict refuses when `overall in [:noncompliant, :unknown, :error]` and
   proceeds only otherwise. Treat that triple as one unit everywhere; a guard
   that blocks `:noncompliant` but passes `:unknown` has reinvented the bug
   the lattice exists to prevent.
10. **Findings must be filed, parity is a contract, determinism is
    structural.** A `:noncompliant` outcome without a gap reference is
    refused (rule 5). Direct and Wongi must decide identically — extend the
    parity corpus in the same change that adds IR features. Never introduce
    iteration over maps, random ordering or time into evaluation; sort, then
    emit. Evaluation reads, it never writes.
11. **The IR round trip is lossless, and the hash is the identity.**
    `AshRules.Ir.encode!/1` → `decode/1` reproduces the bundle byte-for-byte:
    the content hash survives the trip, and `decode ∘ encode` is idempotent
    from the first decode on (proved by `test/ir_test.exs` "a compiled bundle
    survives a JSON round trip", over a rule set exercising variables, `neg`
    clauses, gaps, absence semantics and `combining`). The hash is stable
    across declaration order and changes whenever a rule or a schema entry
    changes. Rules are stored sorted by id; Spark metadata is stripped before
    hashing. Never "fix" a hash mismatch by re-hashing — the content changed.
12. **One evaluator behaviour, two engines.** `AshRules.Evaluator.Direct` is
    the default and has zero runtime dependencies; `AshRules.Evaluator.Wongi`
    exists only when the host ships the optional `wongi_engine` dep, and is a
    stub returning `{:error, :wongi_not_available}` otherwise. Never call an
    engine module directly; go through `AshRules.evaluate/3`'s `:evaluator`
    option.

## Guarding a host action (the reference pattern)

The pattern for gating a state-machine action on a bundle — implemented by
`ClinicDemo.Scheduling.Changes.ComplianceGuard` in the clinic-demo host, and
host-agnostic here:

1. **Build facts** as plain triples about the transition being attempted, in
   a vocabulary about policy (e.g. `{subject, :patient_weight_recorded,
   true}`), not about storage. Post-compile spelling for subjects (rule 7).
2. **Decode the *activated* bundle** — `AshRules.Ir.decode(bundle.rules_json)`
   — never evaluate a rule module directly; what is in force is a row, not
   code.
3. **Evaluate and block on the triple** `[:noncompliant, :unknown, :error]`
   (rule 9), with the fired rules' gap texts as the refusal message.
4. **Step aside when no bundle is active** (a fresh host is not noncompliant),
   **fail closed** when a bundle cannot be decoded or evaluated (the one
   state a compliance guard may never occupy is "the rules were unreadable,
   so proceed"), and **record the evaluation after the transaction,
   best-effort** — the audit row is written after the fact and its failure is
   a warning, never a veto of a decision that legitimately passed.

## Agent integration

`ash_agent_tools` ships rules tooling that activates behind this package as
an **optional dependency**: add the dep, and `mix ash_agent.rules [MODULE]
[--facts JSON | --bundle FILE --facts JSON]` plus `AshAgentTools.rule_sets/0`
/ `evaluate_rules/3` list loaded bundles, describe one (revisions, combining,
content hash, fact schema with absence semantics, rules with predicates), and
**dry-evaluate** — pure, no host state read or written. `AshAgentTools.availability/0`
reports whether the integration is active; without the dep the tools answer
with a structured error naming it, never a crash. Absence semantics are
honored there too: read `overall` before any `compliant`.

On the symbols side, no tooling is rules-specific: a `fact_schema do ... end`
block is a generic Spark extension section, so its entities surface as kind
`rules_fact_schema` in `semantic_search/2` and resolve via name paths like
`MyApp.Rules/rules_fact_schema/status` — use that to find fact names for
semantic edits, and the rules tool to see them in rule context.

## Pin note

Not on Hex. GitHub dependency, and the repository is private:

```elixir
{:ash_rules, github: "lukegalea/ash_rules"}
```

Pin it, and note the CI consequence: hosts (and this repo's own workflows)
need a PAT-configured git rewrite to fetch it.
