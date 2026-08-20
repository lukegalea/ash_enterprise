# Plan — Decisions are DMN, and FEEL is the one expression language

- **Status:** **BUILT**, with one named exception. The expression language, the decision resources, the
  compiler, the evaluator, the conformance harness and the dmn-js editor all exist and are exercised by
  the demo in [`ash-bpmn-in-reference-app.md`](ash-bpmn-in-reference-app.md). **Publish-time overlap and
  completeness analysis (§7) is designed and not built**, and it is marked where it appears. The editor
  landed later than the rest and §9 records what it still cannot do.
- **Date:** 2026-08-20
- **Written after the fact.** This is the exception to the convention in [`README.md`](README.md) that a
  plan precedes its code, and it should be read as a design record rather than as a forecast. The
  forecast lives in [`business-process-modelling.md`](business-process-modelling.md) §10.7, which asked
  where DMN sits and guessed wrong about the answer; the correction appended to that document says how.
- **Records:** `ash_decisions` 0.1.0 (MIT, first-party, not on hex) over `boxic_dmn` 0.3.0 and
  `boxic_feel` 0.2.0 (both Apache-2.0, both on hex), and the deletion of `AshBpmn.Expr`.

---

## 1. Why not a second bespoke expression language

`ash_bpmn` shipped with one. `lib/ash_bpmn/expr.ex` was **571 lines** of hand-written tokenizer,
recursive-descent parser and evaluator, and its entire job was to decide `subject.amount > 100` at an
exclusive gateway. It is deleted (`ash_bpmn` commit `93c5797`).

The feature — decision tables, versioned rules, a business analyst changing a threshold without a deploy
— is the smaller half of the argument for deleting it. The larger half is that the module had two
defects of a kind that a hand-written expression language reliably grows, and both were found by reading
it rather than by anything failing.

**A tenant admin could exhaust the atom table.** `expr.ex:537` and `:541`:

```elixir
defp do_resolve([part | rest], ctx) when is_map(ctx) do
  val =
    if is_struct(ctx) do
      # Structs use Map.get on field atoms
      Map.get(ctx, String.to_atom(part))
    else
      # Regular maps: try atom key then string key
      case Map.get(ctx, part) do
        nil -> Map.get(ctx, String.to_atom(part))
```

`part` is a segment of a dotted path taken from BPMN XML — a document a tenant administrator authors in
the designer and publishes. Atoms are never garbage collected. A process whose gateway conditions
reference enough distinct path segments takes the node down, and the limit is a VM-wide one, so it takes
every tenant down with it. This repository's own `AGENTS.md` states the rule that breaks: *"Don't use
`String.to_atom/1` on user input (memory leak risk)."* It is one of the general Elixir rules, near the
top, and it was violated by a first-party package.

**Every evaluation failure became "branch not taken".** `expr.ex:56-59`:

```elixir
def eval(ast, ctx) when is_map(ast) and is_map(ctx) do
  {:ok, do_eval(ast, ctx)}
rescue
  _ -> {:ok, false}
end
```

A typo in a field name, a type error, a missing key and a genuinely false condition all produced the
same value, and nothing anywhere recorded which had happened. That is the worst available failure mode
for a routing decision: a process quietly takes its default branch forever, the diagram says it should
not, and there is no evidence to look at.

So the migration is a fix carrying a feature rather than the reverse. That ordering matters for the ADR,
because it changes the question from *"is DMN worth adopting?"* to *"given that this has to be replaced,
what replaces it?"*

### What FEEL fixes by construction, and what it does not

The atom problem is gone by construction: FEEL context keys are binaries, and `AshBpmn.Subject` resolves
module names with `String.to_existing_atom/1`.

The silent-false problem is fixed by taking FEEL's three-valued logic seriously instead of flattening
it. `null` is not `false`. The branch is still not taken, but the interpreter records a
`:condition_null` process event, because a condition that is silently never true is exactly the bug you
want to be able to see.

**And FEEL's three-valued logic is not uniform, which is a real diagnostic gap and is documented rather
than papered over.** `subject.missing > 100` is `null` — an ordering comparison against an absent value
is undefined — but `subject.missing = true` is plain `false`, because equality against `null` *is*
defined. So an ordering comparison on an absent field leaves an event to find, and an equality
comparison on the same absent field takes the default branch with nothing recorded. That asymmetry is
FEEL to specification. It is stated in `AshBpmn.Feel`'s moduledoc, pinned by a test, and named in
`ash_bpmn` usage rule 9 — the right treatment for a specified behaviour that will nonetheless surprise
whoever hits it.

**One trap is worth stating separately because it is silent, host-side, and one line to fix.** Boxic
parses a numeric literal to a `Decimal`. Comparing a `Decimal` against an Elixir integer is a type
error, which FEEL folds to `null`, which a gateway reads as "branch not taken" and a decision table
reads as "no rule matched". A host that hands the engine a plain map of Elixir integers therefore gets a
silently wrong answer with no error anywhere. Both packages solve it the same way and both make it a
rule: every context value goes through `AshBpmn.Feel.to_feel_value/2` or
`AshDecisions.Feel.to_feel_value/2`, which converts integers and floats to `Decimal`. That conversion
also **drops** `Ash.NotLoaded` and `Ash.ForbiddenField` rather than nilling them, on the reasoning that a
dropped key is a missing path is `null` — the honest answer for a value we do not have, and the only
safe one for a field the actor may not read.

**The compiler now refuses a `conditionExpression` declaring any language but FEEL**, with the flow id in
the error. BPMN permits a document to say it is JUEL or Groovy. Accepting one and evaluating it as FEEL
is the quiet way a diagram and a system come to be about different processes.

### The migration test that mattered

`test/ash_bpmn/expr_test.exs` — 393 lines — was **deleted rather than ported**, because most of what it
asserted is behaviour FEEL deliberately contradicts: `"a" > "b"` is false; `x != nil` is false when nil;
every error is false. Porting it would have encoded the old semantics as a requirement.

What replaced it is the adapter's own suite plus a migration test that pins the only property which
actually had to survive: **every condition in every shipped diagram routes the way it did**. It reads
the conditions out of the fixture files rather than from a list in the test, so a diagram edited later
is covered without anyone remembering to extend it.

---

## 2. Adopt, do not build — and the decision was measured

Writing a conforming FEEL implementation was costed at 60–90 person-days. That is a real number and it
was nearly spent: the original plan had a `dmn_feel` package in it.

It was not spent, because a conforming engine already existed in Elixir and **nothing was written until
there was a number for it**. `boxic_dmn` 0.3.0 and `boxic_feel` 0.2.0 (Apache-2.0, on hex, by a single
author) are a native DMN 1.5 loader, validator and evaluator with a decimal128 FEEL underneath. An
independent run of the official DMN TCK — written here, against the *published* packages rather than
their repository HEAD — put them at **97.68%** before any work of ours.

The division of labour that follows from adopting rather than writing is worth stating plainly, because
it is what makes the dependency defensible:

> Versioning, tenancy, authorization, publish-time refusal and the evidence trail are ours. Parsing,
> FEEL and hit-policy semantics are the engine's.

`AshDecisions.Feel` is the **only** module that calls the engine, and `AshBpmn.Feel` is the only one on
the process side. That is one module per package to rewrite if the engine is ever replaced, and the
conformance suite is ours, so a replacement would be *measurable* rather than a matter of hoping.

---

## 3. The conformance measurement, and the four ways its first run was false

The corpus is the official [DMN TCK](https://github.com/dmn-tck/tck), vendored unmodified at pinned
commit `20274cd2ba9cad805db6114f331c743f4b2603a1` — **149 test groups** across compliance levels 2 and
3, **3,495 asserted result nodes**. `mix ash_decisions.tck.verify` proves the vendored tree is
byte-identical to that commit.

```
compliance-level-2      122/126    96.83%
compliance-level-3     3292/3369   97.71%
all levels             3414/3495   97.68%
```

**The first run said 90.73%, and four of the gaps were the runner's fault, not the engine's.** Each is a
distinct way a conformance number gets quietly falsified in the flattering direction, and each is
recorded in the code that fixes it:

1. **`errorResult="true"` does not mean "must raise".** FEEL has no exceptions — an erroneous expression
   evaluates to `null` — and the corpus says so itself by writing
   `<expected><value xsi:nil="true"/></expected>` alongside the flag. Reading the flag as "must error"
   marked a *correct* engine wrong on 186 nodes.
2. **FEEL is decimal128, so a conforming engine returns 34 significant digits where the corpus writes
   15.** Numbers have to agree at the precision the expectation states, which is what the TCK's own
   runners do. Comparing at full precision fails a conforming engine for conforming.
3. **Trailing whitespace in a string expectation is data.** Four groups exist precisely to check that
   `upper case("xyz ")` keeps its space. A runner that trims marks them wrong.
4. **Sibling imports resolve only through `load_file/1`,** and decision-service cases need the case's
   own inputs rather than the model's defaults.

The number is reported as **four outcomes rather than one rate**, because a single percentage cannot
distinguish the interesting failure from the boring one:

| Outcome | Meaning |
|---|---|
| `passed` | The result matched the expectation — including the ~40% of the corpus that expects the engine to *fail*. |
| `failed` | The engine answered, and answered wrong. **This is the number that matters.** |
| `model_error` | The model would not load or validate, so nothing in it was evaluated. |
| `harness_error` | *This* code could not read the expectation file. Ours, and it fails the run outright. |

### The gate fails in both directions

`AshDecisions.Tck.ExpectedFailures` lists **16 groups** (3 at level 2, 13 at level 3) accounting for the
81 outstanding result nodes, each with its reason. `mix ash_decisions.tck` raises when:

- something **fails and is not listed** — a regression, or a newly vendored corpus exposing something; or
- something **is listed and passes** — the entry is stale.

The second half is the load-bearing one. Without it the list becomes a place failures go to be
forgotten, and the pass rate stops being a measurement. With it, **the list can only shrink**, which is
the same posture as `.dialyzer_ignore.exs` with `list_unused_filters: true` in this repository and for
the same reason. A third gate precedes both: any `harness_error` at all fails the run, because a runner
that cannot read the corpus is not measuring anything.

The 81 remaining nodes are four causes, none of them a wrong answer to a well-formed question: external
Java functions (**deliberately** unsupported — a DMN model reaching into `java.lang.Math` is
tenant-authored code execution, and we would refuse it whatever the engine did); a validator stricter
than the schema about optional `id` and `locationURI` attributes; last-digit disagreement in
exponentiation across the loan-amortisation groups; and one decision-service result-shape difference.

**One thing to know about where this runs.** The TCK suite is a **Mix task gated in CI, not an ExUnit
case**, so `mix test` does not run it. That is deliberate — 3,495 assertions over 149 XML models is not
something to pay for on every test run — but it means the conformance number is only defended by the
pipeline, and someone running the suite locally will not notice a regression.

---

## 4. One artifact: the DMN document

`ash_bpmn` usage rule 3 makes the BPMN XML the single artifact. `ash_decisions` rule 1 says the same
about DMN, and it is the same argument transferred verbatim:

> **DMN XML is the single artifact.** Do not generate it from code, do not parse the snapshot back into
> domain structures, do not keep a second copy of a rule table anywhere. A `DecisionTable` table in the
> database *is* a second copy, and the moment it exists someone edits a rule row and the XML disagrees.

That is why there is no `DecisionTable` resource and no `DecisionRule` resource, which is the shape
almost every rules engine in this space ships. Two resources exist:

- **`AshDecisions.Resources.Definition`** — `key`, `name`, `version`, `status`
  (`:draft | :published | :retired`), `xml` (the authored document), `graph` (the compiled snapshot),
  `errors`, `content_hash`, `organization_id`. At most one draft per key, and a publish that refuses to
  run over a compile error. It mirrors `AshBpmn.Resources.Definition` field for field, deliberately:
  those identities, that partial unique draft index and those actions were debugged once.
- **`AshDecisions.Resources.Evaluation`** — an append-only row per invoked decision.

**The stored document is never rewritten.** `content_hash` is what says a snapshot and a document belong
together, so an artifact the store quietly normalized is an artifact whose hash identifies something
nobody sent.

### The snapshot stores FEEL source text, not a parsed tree

This is the one place where the design differs from the obvious implementation, and the reason is about
upgrades rather than elegance. Boxic's AST is tagged tuples containing `Decimal` structs — expressive,
not JSON-able, and carrying no version tag of its own. A compiled expression lives inside a
`Definition.graph`, and a caller pinned to a published definition has to keep evaluating it across an
upgrade of the engine underneath. A tuple tree whose shape may change between releases cannot survive
that.

So the snapshot records the **source text** plus the engine version that validated it at publish time,
and evaluation re-parses through a memoised cache. Text pins nothing; a tree pins a parser. It is also
simpler and more honest than the JSON-codec-with-a-grammar-version the design originally called for: the
text is what the author wrote and what the DMN document already contains.

`ash_bpmn` reached the same conclusion for gateway conditions, and states it as usage rule 9.

### One asymmetry between processes and decisions, on purpose

A **process** definition is pinned by an instance for life; in-flight instances never migrate. A
**decision** is resolved at call time and by default is not pinned.

That looks inconsistent and is not. A process version is a *shape*, and changing it under a running
instance can leave a token standing on a node that no longer exists. A decision is a *rule*, and the
entire reason a business keeps rules outside code is so that changing one takes effect without
restarting what is in flight. A caller may still pin a version deliberately.

---

### Authoring it: the dmn-js editor, and three decisions inside it

The single-artifact rule is what makes a visual editor shippable at all — there is no second
representation for it to disagree with — so the editor is the payoff of §4 rather than a feature beside
it. `AshDecisions.Web.EditorLive` is a `use`-able LiveView in the package; the host module is thirty-odd
lines supplying an actor MFA, and `/app/decisions/:key/editor` sits in the same `:process_surfaces`
live_session as the BPMN designer. Three decisions inside it are worth recording because each had a
plausible wrong answer.

**Forking is an explicit act on a button, never a side effect of opening an editor.** Both editors create
a draft from a blank *template* when no draft exists. For a key nobody ever published that is exactly
right; for a key with a platform baseline it is exactly wrong, because the answer there is a **copy** of
what the tenant runs today, not an empty canvas. So `Resolver.fork/4` is called from a "Customize" button
on the catalogue, and the editor only ever opens a draft that already exists.

That is not only ergonomics. It is what keeps the load-bearing default of
[`event-triggered-processes.md`](event-triggered-processes.md) §8 honest: **absence of a binding means
"follow the baseline"**, and a design in which merely *looking* at a decision forked it would turn every
visit into a customization — onboarding would accumulate rows nobody asked for, and
never-customized would become indistinguishable from customized-then-reverted. The fork is also
attributed to the signed-in administrator rather than to a system actor, because forking a rule set is a
person's decision and the audit entry should name them.

**The view tabs are server-rendered, and that is a deliberate round trip.** A DMN document is not one
diagram: dmn-js models it as a list of views — one `drd` for the requirements diagram, plus one per
decision for its boxed expression — and it ships **no view switcher**, so every example application
builds its own. Rendering the tabs client-side would be free; rendering them in the LiveView costs a
round trip to switch between two views of a document already sitting in the browser. It is worth paying,
because the alternative is a second design system inside one page: tabs that inherit the application's
components look like the application, and a hook that draws its own does not. The client tells the server
what views exist (`views_changed`) and the server owns which one is current.

**A new draft's template is DMN 1.3, not 1.5.** 1.3 is the namespace dmn-js reads and writes, and
`AshDecisions.Dmn.Profile` normalises it on the way into the engine (§5), so a 1.5 template would be a
template the editor itself cannot open. The template is also a *valid* document rather than an empty
`<definitions/>`, because the create action compiles what it is given — an empty one would store a
definition whose `errors` list is populated before the author has done anything wrong. And what gets
stored is whatever the author submitted, **byte for byte**: the document is never rewritten on the way to
storage, because `content_hash` is what says a snapshot and a document belong together.

Seven tests in the package drive the real save-and-publish lifecycle through the editor's hidden forms
rather than asserting on the hook, which required a web endpoint in its `test/support/` — the cost of
testing a LiveView a package ships for someone else to mount.

## 5. The DMN revision gap between the editor and the engine

Two halves of the toolchain disagree about which DMN they speak, and it is an integration that simply
does not work rather than a preference to argue about:

- **`dmn-js`**, the bpmn.io modeller and the only serious browser DMN editor, has emitted **DMN 1.3**
  since its 8.0.0 release and still does at 17.x — namespace `.../spec/DMN/20191111/MODEL/`.
- **`boxic_dmn`**, the engine, loads **DMN 1.5** — `https://www.omg.org/spec/DMN/20230324/MODEL/` — and
  refuses anything else outright with `:dmn_version_mismatch`. Its own conformance document is explicit
  that it *"never upgrades or downgrades a document implicitly."*

So a document drawn in the designer is rejected by the engine that has to run it.

`AshDecisions.Dmn.Profile` closes it **on the way into the engine and nowhere else**. It rewrites the
MODEL and FEEL namespace URIs — eight of each, because both the `http` and `https` spellings appear in
the wild and exporters are inconsistent about which — and does nothing else: no element added, removed,
renamed or reordered. A document already declaring 1.5 is returned unchanged, and a document declaring
no DMN namespace at all is also returned unchanged, on the reasoning that it is not ours to fix and the
engine's own error is clearer than anything the module could invent.

**The safety of that rewrite is measured, not argued.** The vendored corpus is DMN 1.5, so
`mix ash_decisions.tck --downgrade` rewrites every model to the 1.3 namespaces first and re-runs the
whole suite. **Identical numbers with and without it — 3414/3495 both ways — is the claim.** That is a
stronger statement than any argument from the specification text, because it is a statement about
precisely the constructs the corpus exercises.

It also bounds what the conformance number means: it is a statement about **DMN 1.5 documents
specifically**. That is what upstream ships, and there is no 1.2/1.3/1.4 corpus to measure against.

---

## 6. What is refused, and why refusal is the posture

A DMN document is drawn by a business analyst and then executed by this application, and the whole value
of that arrangement rests on the diagram and the system being about the same decision. **An element the
compiler skips silently is the exact mechanism by which they stop being** — the analyst adds a boxed
context, sees it in the designer, and the running system decides as though it were not there. Nobody is
told, and the divergence runs in the direction of the analyst believing something false.

So the compiler refuses, by element id, with the id in the error. `ash_bpmn`'s graph compiler takes the
same posture toward BPMN elements outside its executable subset, for the same reason.

### The two hit policies that are refused, and why it is not a gap

Implemented: `UNIQUE`, `ANY`, `FIRST`, `PRIORITY`, `COLLECT` and its aggregators (`SUM`, `COUNT`, `MIN`,
`MAX`).

Refused: **`OUTPUT ORDER`** and **`RULE ORDER`**. Both make the *ordering of the result list*
semantically significant, so the answer depends on where a rule sits in the document rather than on what
the rule says. That is a decision whose meaning changes when someone drags a row.

The tie to this repository is direct and is the reason the refusal is a platform decision rather than a
package preference. `CLAUDE.md` non-negotiable 2 forbids `forbid_if` for row access because a
single deny rule reintroduces order-dependence into a model whose correctness rests on being a pure
union of grants. `RULE ORDER` is the same defect wearing a different hat, in a store that is versioned
and auditable precisely so that *what the rules say* is the whole of the answer. Camunda refuses both as
well, so refusing costs nothing in interchange.

**The engine supports all seven.** `boxic_dmn`'s validator and evaluator handle `RULE_ORDER` and
`OUTPUT_ORDER` perfectly well. The refusal is ours, which is worth recording so that nobody later
"fixes" it by reaching past the compiler.

Also refused: an `aggregation` attribute on a table that is not `COLLECT`, because DMN gives it no
meaning there and the engine would ignore it — the silent divergence again, in miniature.

### Boxed expressions, and the rest

Supported: `decisionTable` and `literalExpression`, plus multi-decision DRDs joined by
`informationRequirement` edges, evaluated as a topological walk. Multi-decision DRDs are the normal case
— that is what a DRD is for.

Refused at compile time:

| Refused | Why |
|---|---|
| `context`, `invocation`, `relation`, `functionDefinition`, `list`, and the DMN 1.5 additions (`conditional`, `filter`, `for`, `every`, `some`) | Supportable, simply not supported yet. The error names which one and where. |
| `businessKnowledgeModel`, `decisionService`, and the `knowledgeRequirement` edges pointing at them | Invocable units this package does not evaluate. |
| Unresolvable `informationRequirement` references, and cycles | A DRD whose decisions require each other has no evaluation order. |
| External functions | Tenant-authored code execution. Also one of the 16 known TCK failure groups, so the engine's gap and the policy already agree. |

And on the process side, `ash_bpmn` rule 11: **a gateway condition is FEEL, never a decision
reference.** The composition is business rule task → promote a signal → gateway reads `routing.<name>`.
A gateway that dereferenced a decision would do I/O — a database read, a possible failure, a possible
timeout — inside a code path that is otherwise pure and in-process, and it would put the decision back
*inside* the graph, which is the line the architectural rule exists to hold. It also puts the decision
on the diagram where a reader can see it, instead of hiding it in a condition string.

---

## 7. Every expression is hostile input

Rules are authored by tenant administrators. None of the following comes from the engine:

- **A killed-process timeout.** Evaluation runs under `Task` and is shut down `:brutal_kill`.
- **Size and depth bounds at parse time**, applied at publish rather than at evaluation.
- **No external functions**, and no escape hatch to call host code from a decision.

**One limit is stated rather than papered over.** Every expression that is a plain FEEL expression is
parsed at compile time, so a document that compiles is a document whose expressions are known to parse
and to be within both bounds. **Decision table input entries are the exception**: they are *unary tests*
— `< 10`, `"a", "b"`, `[1..5]`, `-` — a separate grammar that Boxic parses inside its evaluator rather
than exposing a parser for. They are size-bounded at compile time and validated when they first run. So
a table can publish with a malformed input entry and fail on the first case that reaches that column.

### Overlap and completeness analysis — designed, **not built**

This was intended to be the strongest thing `ash_decisions` offers over a hosted DMN engine, and it is
the one part of the design that did not land. It is recorded here in full because the design is sound and
the reuse it depends on already exists next door.

For `UNIQUE` and `ANY` tables whose cells are S-FEEL unary tests over enumerable domains or numeric
intervals, overlap and gap detection are **decidable** by finite-domain enumeration and interval
algebra. That is exactly `ash_strangler`'s proof-obligation engine
([ADR 0008](../adr/0008-typed-invertible-legacy-mappings.md)), including the part that matters most —
what to do with the undecidable remainder:

- Decidable and overlapping → compile error **with a counterexample input vector**; publish refused.
- Decidable and incomplete → a compile *warning* in `errors`. An intentional gap returning `null` is
  legal DMN and must stay publishable.
- Undecidable — a cell that references another decision, uses arithmetic, or ranges over an unbounded
  domain → recorded in the snapshot as an **unproven obligation**, re-checked at runtime.

**None of this exists.** There is no overlap module, no completeness check, no decidable/undecidable
distinction and no obligations mechanism; `grep` for any of those words in `ash_decisions/lib` returns
nothing. `simple_sat` is declared as a dev/test dependency and is unused, which is the shape of work that
was staged and not started. The consequence, stated plainly: **a decision table with two overlapping
`UNIQUE` rules publishes today**, and the conflict surfaces as a runtime `:unique_hit_policy_violation`
on the first case that hits both rows — an error rather than a silent wrong answer, which is the right
runtime behaviour, and much later than it needed to be found.

The package's own README contradicts itself on this point, listing the analysis under both "what this
package adds" and "what does not exist yet". Take the second.

### Which rule fired is not recorded

An `Evaluation` row carries the decision, the definition's key and version, the inputs, the outputs and
the duration. `matched_rule_ids` is present in the schema and is always `[]`, and so is
`TriggerDispatch.fired_rule` one layer up — the same hole, reached from the trigger side.

That is a limitation rather than an oversight, and the reasoning is worth keeping because it will be
re-proposed: `Boxic.DMN.evaluate/3` returns the decision's value and nothing about how it reached it. We
could re-evaluate every input entry against the inputs ourselves and report the rules *we* think matched
— and that second opinion could disagree with the engine that actually decided, which is worse than not
answering. The column stays empty until the engine can say. `ash_decisions` usage rule 12 states it as a
rule so nobody computes the second opinion.

---

## 8. The dependency, honestly

`boxic_dmn` and `boxic_feel` are **0.x packages by a single author, with roughly 200 hex downloads at the
time they were adopted** — a figure to re-check rather than to quote onward. That is
squarely [tier 3 under thesis 6](../manifesto/06-reversibility.md), and it has to be argued as such
rather than glossed:

- **The exit is one module per package.** `AshDecisions.Feel` and `AshBpmn.Feel` are the only callers,
  and a test fails the build if a second `authorize?: false` or a direct engine call appears.
- **The conformance suite is ours.** A replacement engine can be measured against the same 3,495
  assertions before anything is switched. That converts "we would have to find another one" into a
  bounded, evidenced piece of work.

Both facts are what make the dependency defensible. Without them it would not be.

**Three costs, each of which this repository would rather argue in a document than discover in
procurement.**

**Apache-2.0, not MIT.** Compatible with everything here, and it carries obligations MIT does not: the
licence text and attribution must travel with distributions, and there is an express patent grant with a
termination clause. Worth two precise notes. Neither boxic package ships a `NOTICE` file, so Apache-2.0
§4(d) has nothing to propagate — the obligation is attribution and licence text, not a NOTICE to carry
forward. And `ash_decisions` itself is **MIT**; the Apache-2.0 terms attach to the engine underneath it,
not to the wrapper.

**A declared Elixir constraint we violate.** Both boxic packages declare `elixir: "~> 1.20.0"` in their
`mix.exs` and in their published hex metadata. This repository pins Elixir 1.18.4 on OTP 27 in
`devenv.nix` and in CI, to match what the Ash ecosystem is tested against. They compile and pass here
anyway — the conformance run is the evidence — but *compiles and passes* is not the same as *supported*,
and depending on a package whose stated constraint we violate is not a thing to do silently. Three ways
out: upstream relaxes the constraint, we pin `boxic_* 0.1.x`, or the toolchain moves.

**`xmllint` is a runtime dependency of loading a DMN document.** `boxic_dmn` validates against the
normative XSD by shelling out — `System.find_executable("xmllint")`, a temp file, then
`xmllint --nonet --noout --schema DMN15.xsd` — because the packaged OTP `xmerl_xsd` cannot compile the
DMN 1.5 schema's derivation graph. So `libxml2` is a deployment requirement of anything that loads a
model, and without it **every** model fails to load with `:schema_validator_unavailable`. It is in
`devenv.nix` (`libxml2.bin`), installed in CI (`libxml2-utils`), and in the runtime stage of the
`Dockerfile`. `AshEnterprise.Application` also checks for the binary at boot and **warns rather than
refusing to start**, on the reasoning that an application which does not evaluate decisions is perfectly
usable without it and a hard failure would turn an optional feature into a boot requirement. The
worthwhile follow-up is upstream: a pure-Elixir or optional validation path.

---

## 9. What is not built

Six things, in descending order of how much they are worth.

1. **A way to evaluate a decision from the editor.** The largest gap now that the editor exists, and the
   one most visible to the person the layer is for. There is no panel for supplying sample inputs and
   watching which row fires, so an author edits a table, publishes it, and has still never seen it
   answer. `Evaluation` rows are written only by a business rule task at runtime, which means the first
   real evaluation of a newly published rule happens inside a live process. Everything needed is already
   there — `AshDecisions.Evaluator.evaluate/3` takes a `:record` option precisely so a designer probe
   does not pollute the evidence trail — so this is wiring rather than design, and the absence is the
   difference between "authorable" and "usable".
2. **Publish-time overlap and completeness analysis.** §7. It was going to be the differentiator, and it
   compounds the item above: an author can neither prove a table is well-formed nor watch it run.
3. **A FEEL editor.** `@bpmn-io/feel-editor` is MIT and arrives transitively with dmn-js, unused. So
   literal expressions and unary tests — the most error-prone text in a decision, and the only part the
   compiler does *not* fully validate at publish time (§7) — are typed into a plain input with no
   highlighting and no completion.
4. **Which rule fired.** §7 covers why (`Boxic.DMN.evaluate/3` does not say), and it is repeated here
   because the consequence is not confined to `Evaluation`: `TriggerDispatch.fired_rule` is always `nil`
   too. So the trail records that a decision routed an event and what it returned, and never *why*. Both
   columns exist and wait on upstream.
5. **`mix ash_decisions.export`.** The design said this must exist from day one, on the reasoning that
   [ADR 0009](../adr/0009-strangler-and-bpmn-are-first-party.md)'s reversal section already admits *"In-flight
   process instances are lost; there is no export"*, and knowingly repeating that would be worse than
   doing it once. It was not built. The two mix tasks in `ash_decisions` are `tck` and `tck.verify`; the
   only file-producing path anywhere is `mix ash_decisions.tck --json`. The stored `xml` column is the
   full authored document, so the data is not *lost* — a `COPY` recovers every definition — but "the
   documents are in a column" is not an export, and `ash_bpmn` has no export either.
6. **A `CHANGELOG.md`.** `ash_decisions`' `mix.exs` lists one in `files:` and there is not one. Trivial,
   and it is the sort of thing that becomes untrue quietly.

---

## 10. What this forecloses

- **Reverting FEEL after the first publish is effectively one-way.** Once a definition has been
  published, every `Definition.graph` in the database contains FEEL source text and every in-flight
  instance is pinned to one. Reverting then means draining every instance or writing a translator. This
  is the strongest argument for the phase ordering that was actually used: the engine adapter and
  `ash_decisions` landed *before* `ash_bpmn`'s migration, not alongside it.
- **A `businessRuleTask` in a published process becomes unexecutable if `ash_decisions` is dropped** —
  but **loudly**: the interpreter raises on an unknown node type and the instance fails. That is the
  opposite of the `AshBpmn.Changes.RequireApproval` case ADR 0009 describes, where removal is silent and
  needs a per-site review, and it is worth saying because "loud" is the better failure and it happened
  by accident of how the interpreter is written rather than by design.
- **The lockstep is a diamond, and one corner is someone else's.** `ash_bpmn` and `ash_decisions` must
  agree on a `boxic_feel` version, and its release cadence is not ours. One mitigation exists — the
  single adapter module per package — and the other does not: the design called for a CI job in
  `ash_enterprise` that builds all four repositories from their working trees, and **there is no such
  job**. CI resolves the diamond only at the SHAs `mix.lock` pins, and four-way agreement is checked by
  hand against a clean re-fetch of the git dependencies. `ash_strangler` being red on `main` for four
  consecutive runs is the precedent for why "green locally" is not evidence.
- **Refusing `OUTPUT ORDER` and `RULE ORDER` refuses a document a customer may already own.** The
  compile error names the table, which is the most that can be done about it. There is no import path
  that rewrites such a table into an equivalent one, and there should not be: the rewrite would have to
  guess at intent.

## Further reading

- [ADR 0027 — FEEL is the one expression language](../adr/0027-feel-is-the-expression-language.md) and
  [ADR 0028 — decisions are DMN, measured against the TCK](../adr/0028-decisions-are-dmn.md) — the
  decisions this document is the working for.
- [`ash-bpmn-in-reference-app.md`](ash-bpmn-in-reference-app.md) — the adoption and the demo that
  exercises all of the above.
- [`business-process-modelling.md`](business-process-modelling.md) — the original argument, plus the
  appended correction recording where this work contradicted it.
- [`event-triggered-processes.md`](event-triggered-processes.md) — how a decision comes to be evaluated
  in the first place: trigger match, FEEL guard, DMN route.
- [thesis 6](../manifesto/06-reversibility.md) — the tier the engine sits in, and why.
- [thesis 7 §3](../manifesto/07-what-we-do-not-have.md#3-approval-workflows--maker-checker) — the
  remaining limits, stated as gaps rather than as design.
