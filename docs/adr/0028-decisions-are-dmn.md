# ADR 0028 — Decisions are DMN, measured against the TCK, in their own first-party package

- **Status:** accepted
- **Date:** 2026-08-20

## Context

A business rule — *is this access request high risk?*, *which approval chain applies?*, *what is this
contract priced at?* — is configuration, not code. It changes on a business timescale, it is authored
by people who do not deploy, and when it changes an auditor wants to know which version decided which
case. Holding it as an `if` in an Ash action answers none of those three.

[ADR 0027](0027-feel-is-the-expression-language.md) settled the language. This ADR settles four
things it did not: whether the decision layer lives here or in a package, what the artifact is,
which of DMN we implement, and — the part that took the longest and is the reason to trust the rest
— **how good the engine actually is.**

The last one was deliberately not answered by reading a README. The plan budgeted 60–90 person-days
to write a FEEL engine, and the only responsible way to decide against that was to measure the
alternative. So an independent runner over the official **DMN Technology Compatibility Kit** was
built first, against the *published* `boxic_dmn` and `boxic_feel` packages rather than against a
repository HEAD anyone could have tuned to the corpus.

## Decision

**Decisions are DMN documents held as versioned Ash resources in a new first-party package,
`ash_decisions`, evaluated by an adopted engine whose conformance we measure ourselves.**

### 1. A package, not a domain in this repository

`ash_bpmn` reaches a decision only through a configured `AshBpmn.DecisionResolver`, so the process
engine has no dependency on this one. That seam is what makes two packages the right count rather
than one: a host can adopt the process engine with a hand-written resolver over a config file, or
adopt decisions with no process engine at all and serve pricing rules over JSON:API. Folding
decisions into `ash_bpmn` would weld two products together for no gain, and folding them into
`ash_enterprise` would make the one capability most likely to be wanted standalone the one thing you
cannot take.

### 2. One resource holds the model

`ash_bpmn` usage rule 3 — *"BPMN XML is the single artifact; do not keep a second copy of the process
anywhere"* — is what makes a visual designer shippable without the round-tripping problem, and it
transfers verbatim. **A `DecisionTable` table and a `DecisionRule` table *are* a second copy**, and
the moment they exist someone edits a rule row and the XML disagrees. So
`AshDecisions.Resources.Definition` holds `key`, `name`, `version`, `status`
(`:draft | :published | :retired`), `xml` — the document, byte for byte, `trim?: false` — plus the
compiled `graph`, `errors`, `content_hash` and `organization_id`. Same identities, same partial
unique draft index and same lifecycle as `AshBpmn.Resources.Definition`, because those were debugged
once already.

`AshDecisions.Resources.Evaluation` records what the audit log structurally cannot: which decision,
which version, what it saw, what it answered, how long it took, and the correlation id. It is written
for a business rule task and **never for a gateway condition** — a gateway is in-process FEEL, and a
row per branch evaluation would put a database write on every advance. One log, not two.

**`:base`/`:base_opts` and a tenancy test shipped on day one.** That is the single most valuable
lesson from [ADR 0009](0009-strangler-and-bpmn-are-first-party.md), where `ash_bpmn` arrived with
tenancy declared-but-not-plumbed and policies declared-but-absent, and closing both took three fixes
and a second tenant-scoped copy of the test tables. Writing it in before there are users cost an
afternoon.

### 3. What is implemented, and what is refused at compile time

**Hit policies.** `UNIQUE`, `ANY`, `FIRST`, `PRIORITY` and `COLLECT` with its `SUM`, `COUNT`, `MIN`
and `MAX` aggregators — the DMN `aggregation` attribute values behind the `C+`, `C#`, `C<` and `C>`
shorthand a modeller sees.

**`OUTPUT ORDER` and `RULE ORDER` are refused**, and this is the one refusal worth arguing rather
than listing:

> hit policy OUTPUT ORDER is refused: it makes the order of the result list significant, so the
> decision's answer depends on where each rule sits in the document rather than on what the rules
> say.

That is the order-dependence non-negotiable #2 rejects for authorization, arriving in a different
part of the system. A decision whose meaning changes when someone drags a row is the wrong thing to
put in a versioned, auditable rule store. Camunda refuses both as well, so refusing costs nothing in
interchange. An `aggregation` on a non-`COLLECT` table is refused too, because DMN gives it a meaning
only under `COLLECT` and the engine would otherwise silently ignore it.

**Boxed expressions: `decisionTable` and `literalExpression`.** Multi-decision DRDs joined by
`informationRequirement` edges are supported — that is what a DRD is *for* — with **requirement-cycle
detection** by reachability search and refusal of dangling references. Everything else — `invocation`,
`context`, `relation`, `functionDefinition`, `list`, `conditional`, `filter`, the iterators,
`businessKnowledgeModel` and `decisionService` — is **refused with the element id in the error**, for
`ash_bpmn`'s stated reason: silently ignoring an element a business analyst drew is how a diagram and
a system quietly become about different processes. Errors accumulate, so an author sees every problem
in one pass rather than one per publish attempt.

Compilation runs on every write of `xml` and publishing refuses over a non-empty `errors`, so "refused
at compile time" is enforced at write and *gated* at publish.

### 4. DMN 1.3 in, DMN 1.5 to the engine, and the document you drew is the document you can export

Two halves of the toolchain disagree about which DMN they speak, and neither is wrong. **`dmn-js`** —
the bpmn.io modeller, and the only serious browser DMN editor — has emitted **DMN 1.3** since its
8.0.0 release and still does at 17.x. **`boxic_dmn`** loads **DMN 1.5** and refuses anything else
outright with `:dmn_version_mismatch`. So a document drawn in the designer would be rejected by the
engine that has to run it. That is not a preference to be argued about; it is an integration that
does not work.

`AshDecisions.Dmn.Profile` rewrites the `MODEL` and `FEEL` **namespace URIs** — from any revision the
corpus and the tooling actually produce, 1.1 through 1.4, in both the `http` and `https` spellings the
OMG published them under — to 1.5. Nothing else: no element added, removed, renamed or reordered.
That narrowness is the whole safety argument, because for the subset this package executes the
structure is identical across those revisions, and everything outside that subset is already refused
with the element id before normalization runs.

**The normalized document is never stored.** `Definition.xml` keeps exactly what the author submitted,
because `content_hash` is what says a snapshot and a document belong together, and an artifact the
store quietly rewrote is an artifact whose hash identifies something nobody sent. Normalization
happens on the way *into* the engine and nowhere else — three call sites, all inbound.

**The safety claim was checked by measurement, not by reading specification diffs.** The vendored TCK
corpus is entirely DMN 1.5, so it was **downgraded** — every model rewritten to the 1.3 namespaces —
and the whole conformance suite re-run through `Profile`. Identical results, group by group: 3,414 of
3,495 both ways.

## Results — the conformance measurement

This is the part that makes the rest of the ADR a decision rather than a preference.

`priv/tck/` holds the official DMN TCK corpus, pinned at commit
`20274cd2ba9cad805db6114f331c743f4b2603a1` and hash-guarded — `mix ash_decisions.tck.verify`
recomputes SHA-256 over every vendored file and fails on any modification, addition or removal, so
the corpus cannot drift into agreement with the engine. **146 test groups**, 150 DMN models (four
groups import siblings), and **3,495 asserted result nodes**: 126 at compliance level 2 and 3,369 at
level 3.

```
compliance-level-2      122/126    96.83%
compliance-level-3     3292/3369   97.71%
all levels             3414/3495   97.68%
```

**The first run said 90.73%, and four of the gaps were the runner's own fault.** Each is a way a
conformance number gets quietly falsified, so each is recorded in the code that fixes it:

1. **`errorResult="true"` does not mean "raise".** FEEL has no exceptions — an erroneous expression
   evaluates to `null` — and the corpus says so itself by writing
   `<expected><value xsi:nil="true"/></expected>` alongside the flag. Roughly 40% of the corpus
   carries it (1,409 of 3,495 nodes), so reading it as "must error" marked a correct engine wrong on
   nearly every division-by-zero and type-mismatch case there is. The runner now accepts either an
   error or a `nil`.
2. **FEEL is decimal128 — 34 significant digits — and the corpus writes its expectations rounded.**
   `0008-LX-arithmetic` expects `2778.69354943277` where a conforming engine computes
   `2778.693549432766768088520383236288`. Comparing those with `Decimal.equal?/2` marks a *correct*
   engine wrong, so a number matches when it agrees **to the precision the expectation states**,
   which is what the TCK's own runners do.
3. **Trailing whitespace in a string expectation is data.** `<value xsi:type="xsd:string">XYZ </value>`
   asserts a trailing space, and four groups exist precisely to check that it survives —
   `upper case(string:"xyZ ")` is `"XYZ "`. Trimming reports a correct engine as wrong.
4. **Sibling imports resolve only through the file-based loader**, and this one ended somewhere more
   interesting than a fix. Two groups import sibling documents that only `Boxic.DMN.load_file/1`
   resolves relative to the model's directory. The runner deliberately does **not** use it: it reads
   the bytes and normalizes them, so the corpus exercises the same path a published `Definition`
   takes. Both groups are consequently expected failures. That is a real trade — a slightly lower
   number in exchange for the corpus testing the compiler and not only the engine — and the comment
   describing the fix is now stale beside the code that chose otherwise.

**The 81 remaining result nodes are characterised, not rounded away.** `AshDecisions.Tck.ExpectedFailures`
lists **16 groups**, each with a reason, and the suite fails **both** when something unlisted fails
*and* when something listed starts passing — *"the list may only shrink."*

| Groups | Cause | Ours to fix? |
|---|---|---|
| 1 | External Java functions (`0076-feel-external-java`) | **No.** A DMN model reaching into `java.lang.Math` is tenant-authored code execution. We would refuse it regardless, and `AshDecisions.Feel` refuses it independently. |
| 5 | The validator requires an `id` the DMN schema makes optional, or rejects a decision with no logic, or an import without `locationURI` | Upstream |
| 9 | Last-digit disagreement in exponentiation (the loan-amortisation groups) | Upstream, cosmetic |
| 1 | A multi-output decision service returns the whole context | Upstream, real |

**One limit on that gate, and it is the honest cost of a per-group list.** The excuse is granted per
group, not per node, so the 16 listed groups blanket-cover **1,206** result nodes even though only 81
are actually failing — `0100-arithmetic` alone holds 1,087. A *new* regression inside a listed group
would therefore not fail the build. Tightening the list to node granularity is the obvious next
improvement and is not done.

**And one thing the number is not.** The figures live in the package README and are computed at
runtime by `mix ash_decisions.tck`; no committed artifact pins them, so they are a claim that has to
be re-run rather than a test that fails when it stops being true.

## Does it consume ActorContext?

**Yes, and from the first commit rather than as a retrofit.**

Both resources are instantiated here on `AshEnterprise.Platform.Resource`, so a decision definition
and an evaluation row inherit ownership, tenancy, soft delete, the audit hook and the policy union.
The engine's own writes go through one named bypass, `AshDecisions.Checks.AshDecisionsInteraction`,
declared at the top of [`AshEnterprise.Security.Policies`](../../lib/ash_enterprise/security/policies.ex)
beside the `ash_bpmn` one — the arrangement ADR 0009 recommended, and the one that keeps the *human*
actor so ownership, provenance and the audit entry still name the person. A tenancy test with a second
tenant-scoped copy of the tables shipped with the package.

**A decision decides; it does not act and it does not authorize.** That line is the reason this can
sit inside the platform at all. A rule expressed here that *enforced* something would be enforced in
one place and bypassed by every other caller — the controller-layer authorization mistake in a new
costume, and precisely what
[thesis 1](../manifesto/01-model-your-domain.md) exists to eliminate. `ash_bpmn`'s business rule task
routes on the answer and the mutation that follows is an ordinary Ash action with its own policies.

**One deliberate widening, stated as such.** `AshEnterprise.Process.DecisionResolver.exists?/1` — the
publish-time check that a business rule task names a decision that exists — reads with `tenant: nil`,
because tenancy is not available at compile time. So it asks the broadest version of the question: is
there a published decision anywhere by this key? A tenant publishing a process against a key only
*another* tenant has is therefore caught at execution rather than at publish. That is the weaker of
the two guarantees and the moduledoc says so. The check itself queries, which is fine and is worth
saying once so nobody re-litigates it: non-negotiable #3 is about the per-request authorization path,
and publishing a diagram is neither per-request nor authorization.

## Consequences

**What this makes easy.** A rule that changes without a deploy, versioned, tenant-scoped, and with an
evidence row saying which version decided which case — which is the thing a hand-written `case` in an
action cannot produce at all. Interchange with whatever DMN tooling a customer already owns, because
the artifact is a DMN document and not our encoding of one. And a swap that is *measurable*: a
candidate engine's TCK number is directly comparable to 97.68% because the suite is ours.

**What this makes hard, and the first item is the whole risk.**

- **We depend on a 0.x package by a single author with negligible adoption.** That is squarely tier 3
  under [thesis 6](../manifesto/06-reversibility.md) and has to be argued as such rather than
  explained away. What makes it defensible is two specific facts and not a judgement about the
  maintainer: the engine sits behind one adapter module for expressions and three call sites for
  documents, and **the conformance suite is ours**, so replacing it is a measured swap rather than a
  leap. Without both, this dependency would not be defensible.
- **`xmllint` is now a runtime dependency** of anything that loads a DMN document. `boxic_dmn`
  validates against the normative XSD by `System.find_executable("xmllint")` and a temp file, so
  `libxml2` has to reach devenv, CI *and* the release image, and a missing binary presents as every
  model failing to load with `:schema_validator_unavailable` — which looks like a corrupt document,
  not a missing package. `devenv.nix` carries `libxml2.bin` and `AshEnterprise.Application` checks
  for the binary at boot so the failure names itself. Worth asking upstream for a pure-Elixir or
  optional path. The shell-out is also why `AshDecisions.Evaluator` memoises loaded models in
  `:persistent_term`: a process spawn per evaluation is not a thing to do on a request path.
- **The published packages declare `elixir ~> 1.20.0`**, while this toolchain is Elixir 1.18 on OTP
  27 to match what the Ash ecosystem is tested against, and `ash_decisions` itself declares
  `~> 1.17`. They compile and pass anyway. But depending on a package whose stated constraint we
  violate is not something to do silently, and it is unresolved: either upstream relaxes it, or we
  pin an older `boxic_*`, or the toolchain moves.
- **Apache-2.0, not MIT.** Compatible, and it carries a `NOTICE` obligation and a patent grant MIT
  does not. This repository argues licences in ADRs rather than discovering them in procurement.
- **The lockstep is a diamond and one corner is someone else's.** Both `ash_bpmn` and `ash_decisions`
  declare `boxic_feel ~> 0.2` and `boxic_dmn` requires `boxic_feel ~> 0.2.0`, so the tightest edge is
  patch-level and belongs to a package we do not release. See ADR 0009's amendment for the mitigation.
- **We own a DMN subset.** Every boxed expression it refuses is our backlog, refused loudly with the
  element id, which is the honest failure mode and still a refusal.

**What was promised and is not built.** Two things, both named in the plan as important, and saying
so here is cheaper than letting a reader assume:

- **Publish-time completeness and overlap analysis does not exist.** It was billed as the strongest
  thing this package offers over a hosted DMN engine — finite-domain enumeration and interval algebra
  over S-FEEL unary tests, mirroring `ash_strangler`'s proof-obligation engine
  ([ADR 0008](0008-typed-invertible-legacy-mappings.md)) down to what it does with the undecidable
  rest. There is no code for it. Until there is, a `UNIQUE` table with overlapping rules publishes
  cleanly and fails at runtime naming both rule ids, which is a materially weaker guarantee.
- **`mix ash_decisions.export` does not exist.** `ash_bpmn`'s reversal section admits "in-flight
  process instances are lost; there is no export", and the plan's own conclusion was that repeating
  that knowingly would be worse than making the mistake once. It was repeated.

**What the evidence row cannot tell you.** `Evaluation.matched_rule_ids` is always written empty:
`Boxic.DMN.evaluate/3` returns the decision's value and nothing about how it reached it. So the
record answers *"what did it decide, from what, at which version"* and not *"which rule fired"* —
and `TriggerDispatch.fired_rule` is nil for the same reason. That is a real gap in the audit story
this package exists to provide, it is upstream, and it should not be described as anything else.

**What it forecloses.** A decision layer with its own rule tables, and therefore any UI that edits
rules as rows without going through the document. That is the intended trade and it is the one thing
keeping the designer shippable.

## Reversal

**To drop the package from this repository:** remove `{:ash_decisions, github: ...}` from `mix.exs`,
delete `lib/ash_enterprise/decisions.ex` and its two resource instantiations,
`lib/ash_enterprise/process/decision_resolver.ex`, the `AshDecisionsInteraction` bypass and the
`/app/decisions` route; generate a migration dropping `dmn_definitions` and `dmn_evaluations`.
There is no queue to remove — decisions are evaluated inline on whichever worker or request needs
them, which is the right shape for something with a 250 ms budget. **A published `businessRuleTask` becomes
unexecutable** — see ADR 0009's amendment for how loudly. Roughly a day, plus editing every process
that contains one.

**To replace the engine, keeping DMN:** rewrite `AshDecisions.Feel` plus the three `Boxic.DMN` call
sites in `Compiler`, `Evaluator` and the TCK runner, and run `mix ash_decisions.tck` against the
replacement. Stored documents are unmodified DMN, so nothing in the database changes; `Profile` may
become unnecessary or may need a different target revision. Days, and the number tells you whether it
worked — which is the entire reason the suite was built before the code.

**To abandon DMN:** every published decision is a DMN document and every business rule task names one
by key, so this means re-expressing each rule in whatever replaces it and rewriting the resolver. In
practice it is "stop authoring new decisions, drain the processes that use them", not "switch" —
the same shape as [ADR 0015](0015-approvals-stay-in-ash.md)'s reversal, and for the same reason.
