# ash_rules usage rules

_Rules for working with the ash_rules library, for humans and agents alike._

## Compliance is decided by absence, not just presence

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
   verifiers as DSL-authored ones.
2. **Validate before activation, never at evaluation.** Compile-time
   verification is the product: a rule that reaches production with an
   unbound variable has defeated the entire design. When adding rule
   features, add the verifier and its negative test in the same change.
3. **Findings must be filed.** A `:noncompliant` outcome without a `gap`
   reference is refused. Do not relax this for "internal" rules — the unfiled
   finding is the one that cannot be waived, tracked or aggregated.
4. **Parity is a contract.** Direct and Wongi must decide identically. If you
   add IR features, extend the parity corpus in the same change; the
   absence-semantics pre-pass and the network must never drift.
5. **Determinism is structural.** Never introduce iteration over maps, random
   ordering, or time into evaluation. Sort, then emit. The determinism
   property tests are not decoration.
6. **Evaluation reads, it never writes.** The evaluator never persists
   findings, sends notifications or mutates resources. Projection of results
   into host state is `ash_compliance`'s job.
