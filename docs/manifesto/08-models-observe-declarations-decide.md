# Thesis 8 — Models observe; declarations decide

> A probabilistic model is an instrument that produces observations. Only declarations — actions, policies, decision
> tables, rules — turn observations into anything with authority.

This thesis is newer than the other seven and carries less weight of evidence: it is proposed alongside
[ADRs 0038–0047](../adr/README.md), and **nothing it describes is built yet.** It is written now because the decision
is cheapest to reason about before the first call site exists. *Amended 2026-09-28:* the generative rung is typed by
the same declaration and runs in the data's zone; learning loops end in proposals; the novelty claim is narrowed.

## Why this needs saying

For most of this repository's life a model call was an event. It cost seconds and cents, it produced prose, and nobody
was tempted to put one inside an authorization check. [Thesis 5](05-agents-are-users.md) dealt with that world: the
model is a user, it gets the same actions and the same policies, and its writes wait for a human.

A new class of model changes the economics without changing the epistemics. "System One" models — the vendor's name,
borrowed from the fast half of Kahneman's pair — answer a typed question over a piece of text and return a probability
instead of prose. They run in milliseconds, locally, for almost nothing. When a judgment costs that little, the
temptation is to use it everywhere a boolean is currently hand-written: in a policy, in a decision table, in a rule, in
a calculation that happens to be loaded in a list. Each of those is a place where this platform has promised something
a model cannot deliver.

The upstream library this repository already depends on made the call one line. `ash_ai` 1.1.0 ships `evaluate`, typed
answer structs and the versioned model id behind any alias. The question is no longer whether we can; it is where we
must not.

## Two kinds of determinism

The platform's documents say "deterministic" often, and they mean two different things.

**Determinism of evaluation** is the property that the same inputs produce the same output every time. The rules
engine has it by construction. DMN has it by measurement against a conformance suite. A model does not have it and
never will: not across runtime versions, hardware, batch sizes or model tags.

**Determinism of record** is the property that what was decided, from which inputs, by which version, is immutable and
can be reconstructed. That is what an auditor asks for, and it is what an event log provides.

The platform only ever needed to promise the second. [ADR 0035](../adr/0035-compliance-is-projected-from-events.md)
says a replayed compliance answer that disagrees with the original is worse than no answer, and that is a statement
about the *record*. So the move is to convert a model's output from a computation into an observation — the way a
screening result from an outside vendor is treated: a timestamped, provenance-stamped statement of what instrument X at
version Y reported. Once recorded it is data, and everything downstream is deterministic over data. Replay reads the
record and never asks the instrument again. Asking again is a *new* observation.

## The shape

Every probabilistic judgment follows one path.

1. **Observe.** An instrument answers a declared, typed question and the answer is written to a ledger with its full
   provenance: the question's hash, the model's digest, the state it saw, the distribution it returned.
2. **Admit.** A deterministic action turns the observation into a fact, a human task, or nothing. Which one is decided by
   a versioned decision table whose thresholds were earned by calibration, and the action is performed by a human or by
   a principal holding an explicit, revocable grant.
3. **Decide.** Rules, policies and processes evaluate admitted facts as they evaluate any fact. They do not know a model
   was involved.

Three consequences are worth stating as rules, because each is a place the convenient shape is refused:

- **Never in a check, never a grant.** No model runs inside a policy check, an `ActorContext` build, a FEEL expression,
  a rules evaluation, a projector or a calculation. A judgment can reach authorization only as a materialised,
  versioned, appealable fact, and only for the concerns where [thesis 3](03-authorization-is-data.md) already sanctions
  `forbid_if` — and the recommendation is that it reach it not at all.
- **Probabilities stop at the decision table.** What leaves it is a crisp fact or no fact. An unadmitted observation
  writes nothing, so the rules layer's missing-data semantics make the rule `unknown`, and `unknown` never collapses to
  compliant. Uncertainty cannot become a pass anywhere on the path, and nobody had to remember to make that true.
- **Abstention is a result; absence is not evidence.** "Insufficient" and "not found" are first-class answers. A model
  can report what it found; it can never establish that nothing exists.

## The declaration is the shared schema

This is one idea rather than three features because of a property Ash gives us for free: **the declaration a model is
asked about is the same declaration the rest of the platform already reads.**

The `one_of` constraint that validates an attribute is the option list of a `Choice`, so a model cannot choose an
option the schema does not have. The fact schema a rule bundle evaluates is the list of predicates a model may ground.
The action contract that agent tooling validates against is the candidate set a semantic "did you mean" may choose
from. The DMN input that a conformance test exercises is where a probability lands. Because the question is a
declaration, the manifest, the documentation, the agent tooling and the audit pack all see it like any other contract.

The same declaration also shapes what a *generative* model may emit
([ADR 0046](../adr/0046-the-declaration-is-the-output-contract.md)). A prompt action's return type and constraints
become the schema the model is decoded under, so an option that is not declared cannot be produced and a citation
outside the packet cannot be decoded. That fixes the *shape* of an answer and nothing more: a schema-valid answer is
well-formed, not correct, which is why a generative answer is always a proposal that something else verifies.

[Thesis 1](01-model-your-domain.md) said *declare once, derive the rest*. This thesis extends it to inference:
**maximal declaration, minimal inference, and inference always typed and ledgered.**

## The ladder

Every question is answered on the cheapest rung that can answer it exactly. Declarations first — FEEL, rules,
constraints, deterministic checks on amounts, dates and parties — because they are free, exact and explainable. System
One second, for questions that are intrinsically about interpreting language: relevance, support or contradiction,
classification, verifying a proposed value. A generative model third, for the residue that needs text produced: in the
data's zone by default, decoded under a schema derived from the declaration, with no self-reported confidence, citing
only by constrained id, and only ever as a proposal — leaving the zone is a disclosure. A person last, for the middle
band and for anything whose consequence is severe; their verdicts become the evaluation set.

Every answer on every surface says which rung produced it. Descending the ladder is triggered by calibrated uncertainty
declared in a table, never by a branch in code.

## Learning is a proposal

Every learning loop the programme contemplates — searching a question's wording with an optimiser, distilling
reviewer overrides into decision-table rows, mining rule revisions, fine-tuning a local model, fitting a simulator —
ends the same way: in a proposal record with its lineage, never in a live version
([ADR 0047](../adr/0047-learning-produces-proposals.md)). Nothing learned is applied in serving. Adoption is an
approval by a person holding the privilege, and an adopted artefact re-earns its calibration on data its learner never
saw. An optimiser may change only what the declaration leaves open — a question's instructions and criteria, never its
answer type or options. Cheap local inference makes proposing nearly free; it does not make adopting any cheaper, and
that is the point.

## What this does to the other theses

It amends two and adds an entry to a third.

[Thesis 3](03-authorization-is-data.md) gains a sentence it always implied: a probability is not a grant, and a check
that calls a model is a check that queries. The trust extended to automation becomes grant rows like every other
permission ([ADR 0043](../adr/0043-automation-authority-is-a-grant.md)), rather than a threshold in configuration and a
bypass in a policy file.

[Thesis 5](05-agents-are-users.md) said writes need a human. Automatic admission is a write without a human at the
moment it happens, and that is a real change of meaning. It is bounded rather than hidden: the human decision moves from
the moment of the write to the moment of the grant, the grant is per question family and revocable, and whether any
family is ever granted is still open.

[Thesis 7](07-what-we-do-not-have.md) gains an entry, because none of this is built, and two of its existing items —
the missing publish-time overlap check and the decision trail that cannot say which row fired — are preconditions for
auditable threshold tables in this repository. Both are fixed in the decision package upstream and not yet adopted here.

[Thesis 4](04-batteries-are-inherited.md) is unchanged and worth restating: the judgment ledger is an ordinary platform
resource, and the temptation to exempt "AI infrastructure" from audit for volume reasons is exactly the silent opt-out
that thesis exists to prevent. [Thesis 6](06-reversibility.md) is unchanged too: the judgments package is tier 3, and
both instruments are services behind a network boundary that hold no authorization model of their own.

## The steelman against this thesis

Every rule above moves the model further from authority. So what is it for?

It may never grant. It may never decide a high-consequence predicate. Its thresholds must be earned on labelled data
before they exist, and every model upgrade is a recalibration and an approval. Once fenced like this, its direct value
narrows to two things: **triage throughput** — ordering a review queue, and admitting only boring, low-risk facts — and
**verification**, checking a value something else proposed. That is a much smaller claim than the one the vendor's
marketing makes, and much smaller than the one our own early design notes made, which called these models "learned
decision tables". That phrase is the most dangerous sentence in the material: a pretrained model has not learned *our*
policy; it estimates what a text says. Policy stays declarative.

There is a second objection, and it is about who we would depend on. The hosted instrument comes from a company that
had been public for twelve days when this was written. Its accuracy figures are self-reported or reach us through a
third party's comparison page, and none of them is about our questions.

And a third: learning loops smuggle bias. The only observations a person reviews are the middle band, so any threshold
tuned on reviewed data, and any rule mined from overrides, inherits that selection. Proposals distilled from it encode
reviewer habit as much as policy.

And a fourth: it isn't new. It is not, in its formal parts. Grounding predicates with a neural model and evaluating
them with logic is DeepProbLog (2018) and Scallop (2023); the closest recent work, PL-Guard (2026), has a local model
ground policy predicates to probabilities that ProbLog rules then combine. Validating model output against declared
types is TypeChat (2023) and type-constrained decoding (PLDI 2025). Anyone presenting this design as a first would be
wrong.

## Why proceed anyway

Because the valuable part is not the model.

The declared question, the ledger row, the band table and the evidence packet are worth building **even with a person
in every loop.** The same record is the audit artifact, the reviewer's screen, the regression fixture, the calibration
unit, the training example and the explanation. A reviewer who is shown the exact clause by page and character range,
the predicate it was checked against and the reason it was routed to them is faster and more consistent than one who is
shown a document and a rule — whether or not a model ever admits a fact on its own.

So the model is the replaceable part and the substrate is the durable one, and the programme should be judged on the
narrow claim first: a measured reduction in review time at a fixed error rate, on one slice, in one jurisdiction. The
answer to the vendor objection is structural rather than contractual — the default instrument runs in the data's zone, a
contract test watches the wire between two parties with no agreement between them, and removing either instrument
degrades triage rather than breaking anything. The answer to the bias objection is procedural and mandatory: random
audit sampling of automatically admitted facts, and every mined rule a proposal that only an approval can promote.

The answer to the novelty objection is to claim less. We differ from the probabilistic-logic work on purpose: it
propagates probabilities through the rules, and we do not. Our rules stay crisp over admitted facts; where a derivation
is shown, each leaf carries its ledger id, recorded probability and band row as *provenance*, not as a value the rules
compute with. What is distinctive here is operational rather than formal — admission as an authorized action,
instrument identity in the ledger, band tables earned by calibration, source-addressed evidence packets — and it is
judged on one measured slice before it is claimed anywhere else.

## Further reading

- [ADR 0038 — models observe; declarations decide](../adr/0038-models-observe-declarations-decide.md) — the core, and
  the table of where a model call may live
- [ADR 0039](../adr/0039-judgments-are-declared-questions.md) to
  [ADR 0045](../adr/0045-system-one-in-tooling-is-advisory.md) — questions, the ledger, thresholds, zones,
  automation authority, evidence, tooling
- [ADR 0046 — the declaration is the output contract](../adr/0046-the-declaration-is-the-output-contract.md) and
  [ADR 0047 — learning produces proposals](../adr/0047-learning-produces-proposals.md)
- [`../plans/system-one.md`](../plans/system-one.md) — the execution plan, and the decisions still open
- [ADR 0026 — AI governance is disclosure](../adr/0026-ai-governance-is-disclosure.md)
- [ADR 0035 — compliance is projected from events](../adr/0035-compliance-is-projected-from-events.md)
- [PolicyGuard: from organizational policies to neuro-symbolic compliance review engines](https://arxiv.org/abs/2606.32004)
  (arXiv 2606.32004, 2026)
- PL-Guard (arXiv 2608.15673, 2026) — the nearest prior art: a local model grounds policy predicates to probabilities
  that ProbLog rules combine; the difference from this design is that we do not propagate them
- [Conformal selective prediction with cost-aware deferral for safe clinical triage under distribution shift](https://www.nature.com/articles/s41598-026-40637-w)
  (*Scientific Reports*, 2026) — the statistical basis for triage bands
