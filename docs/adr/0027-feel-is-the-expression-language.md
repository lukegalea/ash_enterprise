# ADR 0027 — FEEL is the one expression language, and the engine is adopted rather than written

- **Status:** accepted
- **Date:** 2026-08-20

## Context

`ash_bpmn` needed to answer one question — *is this branch taken?* — and answered it with
`AshBpmn.Expr`: **571 hand-written lines** of tokenizer, recursive-descent parser and evaluator,
for expressions like `subject.amount > 100`. It worked, it was tested, and it was a reasonable
thing to have written for a language with four operators.

Its own usage rule 9 is what made it untenable:

> **Conditions are FEEL, and there is only one expression language.**

Adding a decision layer meant adding expressions in a second place — rule cells, literal
expressions, a routing guard on an audit event. Under that rule, the question was no longer "what
should decisions use" but **"what is the one language, everywhere?"** And once the question is put
that way, a bespoke four-operator grammar has to justify itself against a specified one.

It could not, for two reasons beyond mere unification. Both were found by reading it rather than by
it failing, and both are the kind of defect that never shows up in a test suite.

**It created atoms from tenant-authored input.** `lib/ash_bpmn/expr.ex:537` and `:541` called
`String.to_atom/1` on path segments taken from BPMN XML:

```elixir
537:        Map.get(ctx, String.to_atom(part))
541:          nil -> Map.get(ctx, String.to_atom(part))
```

Atoms are never garbage collected. A tenant administrator drawing a diagram with enough distinct
path segments exhausts the atom table and kills the node — a denial of service authored through the
designer. `AGENTS.md` states the rule this breaks in one line: *"Don't use `String.to_atom/1` on
user input (memory leak risk)."*

**Every evaluation failure silently became "branch not taken."** `eval/2` at `expr.ex:55-58`:

```elixir
55:  def eval(ast, ctx) when is_map(ast) and is_map(ctx) do
56:    {:ok, do_eval(ast, ctx)}
57:  rescue
58:    _ -> {:ok, false}
```

A typo in a path, a type mismatch, a nil where a number was expected — all indistinguishable from a
condition that legitimately evaluated false, in the code path that decides which way a business
process goes.

**The build-or-adopt question was measured rather than argued.** The plan budgeted 60–90 person-days
to write a FEEL implementation. Before writing any of it, an independent DMN TCK runner was built
against the **published** `boxic_dmn` 0.3.0 and `boxic_feel` 0.2.0 (Apache-2.0, on Hex) and produced
a number: **97.68%** of asserted result nodes. That measurement is the subject of
[ADR 0028](0028-decisions-are-dmn.md); its consequence here is that the language question and the
implementation question came apart. FEEL was the right language whether or not a conforming engine
existed; one existed.

## Decision

**FEEL is the expression language everywhere in this platform, and `AshBpmn.Expr` was deleted
outright. There is no shim and no second language.**

`AshBpmn.Expr` and its test file went in a single commit — 571 and 393 lines, `964 deletions(-)`,
the only two file deletions in that repository's history.

**The test file was not ported, and that is a decision rather than an omission.** It encoded three
semantics FEEL deliberately contradicts:

| `AshBpmn.Expr` | FEEL |
|---|---|
| `"a" > "b"` is `false` | strings are ordered; comparison is meaningful |
| `x != nil` is `false` when `x` is nil | `null` propagates through comparison |
| every error is `false` | an erroneous expression is `null`, and `null` is not `false` |

Porting those assertions would have been porting the bugs. Its replacement is the engine's own suite
plus a migration test asserting that each fixture condition, rewritten in FEEL, selects the same
branch for the same context — the only property that actually needed guarding.

**FEEL expression evaluation goes through one module per package.** `AshBpmn.Feel` is the only
module in `ash_bpmn` that touches `Boxic.FEEL` (`feel.ex:100` parse, `feel.ex:151` evaluate), and
`AshDecisions.Feel` is the same seam in `ash_decisions`. Nothing in *this* repository names the
engine at all — `AshEnterprise.Process.Triggers.Dispatch` evaluates a trigger guard through
`AshDecisions.Feel` and that is the only FEEL call in `lib/`. That is what makes the dependency in
[ADR 0028](0028-decisions-are-dmn.md)'s consequences argument a *replaceable* one rather than a
rhetorical one: two modules, not a sweep.

Two honest qualifications, because the packages' own usage rules overstate this. **DMN document
loading, validation and evaluation is a different seam** — `Boxic.DMN` is called from
`AshDecisions.Compiler`, `AshDecisions.Evaluator` and the TCK runner, so "one module calls the
engine" is true of the *expression* language and not of the document engine. And
`AshDecisions.Tck.Value` calls `Boxic.FEEL` directly to parse the corpus's own expected values,
which is defensible — a conformance runner is not on the request path — and is still a second call
site that the rule as written does not admit.

**Numbers must reach FEEL as `Decimal`.** FEEL is decimal128, so an Elixir integer compared against
a FEEL numeric literal is a **type error**, not a coercion. `AshBpmn.Feel.to_feel_value/2` therefore
converts explicitly, and the module says this is the single most consequential line in it:

```elixir
def to_feel_value(value, _depth) when is_integer(value), do: Decimal.new(value)
def to_feel_value(value, _depth) when is_float(value), do: Decimal.from_float(value)
```

**`Ash.NotLoaded` and `Ash.ForbiddenField` are dropped, not passed.** They become a `:__drop__`
sentinel that the map and list clauses discard, so the key is absent. A missing path in FEEL is
`null`, which is the honest answer: an unloaded field is not known and a forbidden field is not this
actor's to see. Passing either through would let a field the actor may not read influence which
branch the process takes.

**The storage form is the FEEL source text, not the engine's AST.** A compiled condition lives
inside `Definition.graph`, and an in-flight instance must keep evaluating it after an upgrade. The
engine's AST is tagged tuples containing `Decimal` structs: expressive, not JSON, and carrying no
version tag. The text is what the author wrote and what the DMN XML already contains, so the stored
form is `%{"language" => "feel", "text" => source}` and evaluation re-parses. Re-parsing pins
nothing; storing a tree would pin a parser.

**The `language` attribute is optional and a wrong one is refused with the element id.** Absent,
empty, `"feel"` and `"FEEL"` are accepted; anything else — `juel`, `groovy` — throws at publish time
naming the sequence flow, because a document written against JUEL would otherwise be published and
then quietly evaluated as FEEL.

**Limits, none of which come from the engine.** A 250 ms evaluation timeout in both adapters,
enforced with `Task.yield/2` then `Task.shutdown(task, :brutal_kill)` — a pathological `matches()`
regex does not yield, so a soft timeout would not be one. A cap on source length, checked before
parsing: 8,192 bytes in `AshBpmn.Feel`, 4,096 in `AshDecisions.Feel`, which is an inconsistency
nobody chose and should be reconciled. `AshDecisions.Feel` additionally bounds nesting depth at 32
and memoises parses in `:persistent_term` keyed by SHA-256. External functions are refused, which is
also the one TCK group the engine is known not to pass, so the engine and the policy already agree.

## Does it consume ActorContext?

**It cannot bypass it, which is the strongest form of yes available to an expression evaluator.**

FEEL evaluation is in-process, pure and has no data access of its own: there is no function to call
a database, and the context a condition sees is built entirely from records the engine has already
loaded through ordinary Ash reads. So a gateway condition is exactly as wide as the read that
produced its subject — it cannot widen it.

The `Ash.ForbiddenField` drop above is the load-bearing part. Field policies are enforced by the
action layer, and a struct returned to the engine can legitimately carry a `%Ash.ForbiddenField{}`
in a field this actor may not read. Handing that to the evaluator would either crash or, worse,
compare successfully against something — either way a field policy would be leaking into control
flow. Dropping it makes the path `null` and the branch unchosen.

Two things follow that are worth stating so they are not re-litigated. Decision references inside
gateway conditions are **refused** (`documentation/topics/what-it-refuses.md`), because dereferencing
a decision performs I/O — a read, a possible failure, a possible timeout — inside the one code path
that has none of them. And the compiler's `exists?/1` check on a business rule task *does* query,
which is fine: non-negotiable #3 is about the per-request authorization path, and publishing a
diagram is neither per-request nor authorization.

## Consequences

**What this makes easy.** One language to document, and one thing to learn for gateway conditions,
rule cells, literal expressions and trigger guards alike. Interchange comes free: a FEEL expression in this repository's BPMN is the same
expression a Camunda or a Trisotech modeller would produce. And a defect class is closed — there is
no `String.to_atom/1` anywhere in the path from tenant-authored XML to evaluation.

**What this makes hard.** FEEL is a real specified language, which cuts both ways:

- **Decimal128 is contagious.** Every number crossing into the evaluator has to be converted, and
  every number coming back is a `Decimal`. Miss a conversion and the failure is not a crash, it is a
  comparison that is a type error and therefore `null` and therefore a branch not taken — the same
  shape as the defect this ADR removed, arriving from the opposite direction.
- **Three-valued logic surprises people.** `x != null` is not `true` when `x` is null. That is
  correct FEEL and it is not what an Elixir programmer expects.
- **An erroneous expression is `null`, because FEEL has no exceptions.** So the silent-false is *not*
  eliminated; it is specified, localized and named. `AshEnterprise.Process.Triggers.Dispatch` folds a
  `null` guard to false explicitly, with the reason written next to it — treating `null` as "fire"
  would start processes from conditions nobody wrote. The difference from the old `rescue` is that
  this is one documented decision in one place rather than a blanket swallow, and a *parse* error is
  now a publish-time refusal rather than a runtime false.
- **The timeout is a wall clock in a pure evaluator**, so a killed evaluation is reported as an error
  rather than as a value. Under load that is a guard that fails rather than a guard that answers.

**Two gaps, recorded rather than smoothed over.** The stored form carries `language` and `text` and
**not** the engine version that validated it, so a snapshot cannot say which parser accepted it —
which is the one thing the storage argument above claimed to buy and does not yet deliver. And
`AshBpmn.Feel`'s moduledoc describes a memoised parse cache keyed by content hash that **does not
exist** in that package: `evaluate/3` parses on every call. `AshDecisions.Feel` does have one, which
is how the claim came to be written down twice and implemented once. Neither gap is load-bearing
today — expressions are small and capped — but a doc describing a cache nobody wrote is exactly the
kind of claim this repository refuses to carry, and both belong in the next pass rather than in a
footnote.

**What it forecloses, and this is a genuine one-way door.** Once the first FEEL definition is
published, every `Definition.graph` in the database holds FEEL and every in-flight instance is pinned
to one. Reverting then means draining every running instance or writing a translator from FEEL back
into a grammar that no longer exists. That is the strongest argument for having done the language
migration *before* adopting the packages here rather than in the same breath, which is how the work
was sequenced.

## Reversal

**Before the first publish** it was cheap and it no longer is; the section is kept because the shape
of the exit still matters.

**To replace the engine, keeping FEEL:** rewrite `AshBpmn.Feel` and `AshDecisions.Feel` — two modules,
`parse`/`evaluate`/`print`/`to_feel_value` between them — against a different FEEL implementation, and
run the TCK suite of ADR 0028 against it. That suite is what makes this a measurable swap rather than
a hopeful one: a candidate engine's number is directly comparable to 97.68%. Stored expressions are
source text, so nothing in the database has to change.

**To abandon FEEL entirely:** reinstate an expression language, translate every published
`Definition.graph`, and drain or migrate every in-flight instance. `AshBpmn.Expr` is not retained
anywhere — deliberately, per [thesis 6](../manifesto/06-reversibility.md)'s preference for a clean
break over a compatibility path — so this is a rewrite, not a revert. The signal that it was necessary
would be the engine being abandoned upstream, which is a reason to change engines rather than
languages.
