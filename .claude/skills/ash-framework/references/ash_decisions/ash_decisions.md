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

## Publish-time verifiers

A host may gate publication on its own evidence (e.g. "this band table has a
calibration run above min-n") without forking the resource:

    config :ash_decisions, :publish_verifiers, [
      {MyApp.Compliance.BandTableGate, :verify, []}
    ]

Each entry is an MFA (`{Mod, :fun, args}`) or a bare module (called as
`Mod.verify/1`). They run **only on the publish action** — evaluation never
consults them — and receive the definition's identity as plain data:
`%{id, key, version, content_hash, status}`, the same shape a certification
record carries, so a band-table gate keys off the family tag the band-table
naming convention puts in the key. A verifier returns `:ok` or
`{:error, reason}`; the **first refusal blocks the publish** and its reason
travels to the caller; a verifier that raises counts as a refusal. Empty
config (the default) leaves the publish action exactly as it was. See
`AshDecisions.Config.publish_verifiers/0`.

## Landing a generated band table

A calibration pipeline (ash_judgments' `ProposalDmn` renderer is the producing example)
finishes with a two-band DMN document — the score gates on the earned threshold, `admit`
above it, `review` below it, and **no default rule**, so a score that is absent or not a
number matches no row and the empty match is a refusal. `AshDecisions.BandTable` is where
that document lands:

    {:ok, published} = AshDecisions.BandTable.land(MyApp.Decisions.Definition, xml)

Import checks the band contract — one decision, `UNIQUE` hit policy, a string `band`
output, no default output entry, and a variable/shape pair the engine can actually
evaluate — and the document then goes through the ordinary lifecycle: draft, compile,
publish-time verification, and any configured `publish_verifiers`. Pass
`publish?: false` to stop at the draft when certification is a person's act, and let
them run `publish!/1` after reading it. The XML is stored byte for byte; the key is the
decision's name, which is where the `bands_<family>` naming convention puts the family
tag a calibration gate keys off. There is no band-table resource and no rule-row import:
the document is the artifact, and a second copy of the rules is a disagreement waiting
to happen.

## Testing

- `mix ash_decisions.tck` runs the vendored DMN TCK corpus and **gates** on it: an unlisted
  failure fails the build, and so does a listed failure that starts passing. The
  expected-failure list may only shrink.
- `mix ash_decisions.tck --downgrade` re-runs the corpus rewritten to DMN 1.3, which is what
  proves the revision normalization changes no answers.
- `mix ash_decisions.tck.verify` proves the vendored corpus is byte-identical to its pinned
  upstream commit. It is share-alike licensed; never edit a test case.
- `xmllint` must be on `PATH` (`libxml2`), or every model fails to load.

## Iron laws

Changes to this package are checked against the 26 Iron Laws (phxagents.dev/iron-laws;
background in `ash_enterprise/docs/research/phxagents-iron-laws-and-codicil.md`).
`ash_agent_tools` ships a deterministic judge for them — `mix ash_agent.laws` reports
violations only, tiered definite/likely/review — wherever that dev tool is installed
(it is part of the `ash_enterprise` program, not a dependency of this package).

- Judge a change before claiming it done: `git diff main | mix ash_agent.laws - --diff`,
  and read the hits' context before acting — the judge is grep-tier, not a parser.
- The laws with teeth *inside a library* are the ones it can see from source: #10 (never
  `String.to_atom` on tenant-authored input — this package bounds and refuses untrusted
  work instead), #16 (`@external_resource` for compile-time file reads), #22 (verify
  before claiming done — compile, test, credo, docs, dialyzer, then say so), #26
  (comments carry durable facts; the narrative belongs to the commit).
- The Phoenix-facing laws (no mount-time queries, `connected?` before PubSub, streams)
  govern the **host applications** that inject `AshDecisions.Web.EditorLive`. The editor
  itself keeps `mount/3` static, loads in `handle_params/3`, and subscribes to nothing.
