# ash_decisions usage rules

_Rules for working with the ash_decisions library, for humans and agents alike._

## What this package is, and is not

It holds **DMN decisions as versioned Ash resources** and evaluates them. It is an Ash layer
over a decision engine (`boxic_dmn` / `boxic_feel`), not a second engine: versioning, tenancy,
authorization, audit, publish-time refusal and the evidence trail are ours; parsing,
FEEL and hit-policy semantics are the engine's.

## The architectural line

> **A decision decides. It never acts, never validates, and never authorizes.**

A rule that *enforced* something would be enforced in one place and bypassed by every other
caller. Business rules that guard a mutation belong in Ash actions, changes and validations.
A decision answers a question; the caller decides what to do with the answer.

## Rules

1. **DMN XML is the single artifact.** Do not generate it from code, do not parse the
   snapshot back into domain structures, do not keep a second copy of a rule table anywhere.
   A `DecisionTable` table in the database *is* a second copy, and the moment it exists
   someone edits a rule row and the XML disagrees. Edit in the designer (or in the XML),
   publish, done.
2. **Definitions are immutable and versioned.** `publish` is one-way. A changed decision is a
   new version.
3. **A caller may pin a version, and by default does not.** This is the opposite of how
   process definitions behave, and deliberately: a process version is a *shape*, and changing
   it under a running instance may leave a token with nowhere to stand. A decision is a
   *rule*, and the reason a business keeps rules outside code is so changing one takes effect
   without a deploy.
4. **Everything goes through `AshDecisions.Feel`.** It is the only module that calls the
   engine, which is what makes the engine replaceable. In particular, put every context value
   through `AshDecisions.Feel.to_feel_value/2`: FEEL numbers are decimal, so a plain Elixir
   integer makes `< 1000` a type error, which is `null`, which a decision table reads as "no
   rule matched" — a silently empty table with nothing reported anywhere.
5. **Refuse at compile time, with the element id.** Business knowledge models, decision
   services, boxed expressions other than decision tables and literal expressions, requirement
   cycles, dangling references. Silently ignoring an element a business analyst drew is how a
   diagram and a system quietly become about different decisions.
6. **`OUTPUT ORDER` and `RULE ORDER` are refused, and this is not a gap.** Both make the
   ordering of the result list semantically significant, so the answer depends on rule
   sequence in the document rather than on the rules. Implemented: `UNIQUE`, `ANY`, `FIRST`,
   `PRIORITY`, `COLLECT` and its aggregators.
7. **The stored document is never rewritten.** `content_hash` is what says a snapshot and a
   document belong together. `AshDecisions.Dmn.Profile` normalizes the DMN revision on the way
   *into the engine* — because `dmn-js` writes DMN 1.3 and the engine loads 1.5 — and never on
   the way to storage.
8. **The snapshot stores FEEL source text, not a parsed tree.** A caller pinned to a snapshot
   keeps evaluating it across engine upgrades; text pins nothing, a tree pins a parser.
9. **Every expression is hostile input.** Rules are authored by tenant admins. Size and depth
   are bounded at parse time, evaluation is killed on timeout, and external functions are
   refused. Do not add an escape hatch to call host code from a decision.
10. **Engine calls go through `AshDecisions.Scope`, never `authorize?: false`.** Each generated
    resource declares one bypass on `AshDecisions.Checks.AshDecisionsInteraction`, and a test
    fails the build if a second `authorize?: false` appears under `lib/`.
11. **A decision can sit on your base resource** via `:base` / `:base_opts`. One ordering rule
    comes with it: a bypass in Ash covers only the policies declared *after* it, and a base
    resource's policies are emitted first — so put `AshDecisions.Checks.AshDecisionsInteraction`
    at the top of the base's policy set.
12. **Which rule fired is not recorded.** The engine returns the value and nothing about how it
    got there. Do not compute a second opinion: one that disagrees with the engine that
    actually decided is worse than no answer.

## Testing

- `mix ash_decisions.tck` runs the vendored DMN TCK corpus and **gates** on it: an unlisted
  failure fails the build, and so does a listed failure that starts passing. The
  expected-failure list may only shrink.
- `mix ash_decisions.tck --downgrade` re-runs the corpus rewritten to DMN 1.3, which is what
  proves the revision normalization changes no answers.
- `mix ash_decisions.tck.verify` proves the vendored corpus is byte-identical to its pinned
  upstream commit. It is share-alike licensed; never edit a test case.
- `xmllint` must be on `PATH` (`libxml2`), or every model fails to load.
