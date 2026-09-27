# ADR 0047 — Learning produces proposals

- **Status:** proposed
- **Date:** 2026-09-28

## Context

[Thesis 8](../manifesto/08-models-observe-declarations-decide.md) allows learning everywhere, but only as proposals.
Until now no record owned that sentence, and the loops it covers are multiplying: optimising a question's wording,
distilling reviewer overrides into decision-table rows, mining rule revisions from outcomes, fine-tuning a local model,
and fitting simulation parameters. Each would otherwise be governed by whichever record it happened to touch —
[ADR 0039](0039-judgments-are-declared-questions.md) for wording,
[ADR 0041](0041-thresholds-are-dmn-earned-by-calibration.md) for thresholds, the rules lifecycle for revisions — and
one rule would be scattered across several.

The facts, verified on 2026-09-28:

- **A capable optimiser exists in Elixir.** `imp` 0.5.0 (MIT; first Hex release 2026-09-27, one day before this record;
  almost all commits by one author) is a port of DSPy with GEPA, MIPROv2, SIMBA and other optimisers. Its
  `Optimize.Anything` (marked experimental) runs GEPA's search over any JSON-safe structured value against an evaluator
  the caller writes, with the value's shape and types frozen by the seed and enforced on every candidate. That fits a
  System One question's `{instructions, criteria per option}` exactly. Its ordinary `Predict`/GEPA path does not: its
  model contract is chat messages in, text out, and a System One call returns a probability distribution.
- **Its results are an artefact with a champion.** An optimiser run yields an artifact holding a champion, challengers
  and previous champions, with `promote`, `rollback` and `apply` operations. Its run events live in memory only; it
  has no database persistence.
- **Its own research is honest about failure.** Published results keep null and negative findings — among them that a
  small local reflection model gave no ranking signal. Optimisation is not guaranteed to find a lift.
- **Local metric calls are cheap; reflection calls are not.** Scoring a candidate wording against a local decision
  model costs milliseconds per call; the expensive part of the loop is the reflection model that proposes new
  candidates. That makes proposing cheap and makes the discipline around adoption the whole cost.
- **Its authorization hook is not ours.** `imp`'s `authorize:` callback fails closed (a crash, timeout, invalid return
  or dead owner all deny), which is good prior art, but it covers only its own agent and recursive-model tool calls and
  runs in a separate task without the Ash actor, tenant, trace context or correlation id.
- **Its recursive-model mode is not retrieval.** "RLM" there means a *recursive* language model: the model writes code
  at run time, in the host VM with the process's authority, to slice its inputs, and answers in strings.
- **A proposal in circulation** has an optimiser commit its champion back as a new question version through an Ash
  action, triggering re-evaluation automatically. That is self-modifying policy wording.
- **Reviewed data is biased.** People review the middle band, so anything fit only on reviewed verdicts inherits that
  selection ([ADR 0041](0041-thresholds-are-dmn-earned-by-calibration.md)'s random audit exists for this reason).
- **Decisions are business-authored** ([ADR 0028](0028-decisions-are-dmn.md)), and approvals stay inside Ash
  ([ADR 0015](0015-approvals-stay-in-ash.md)).

## Decision

**A learning process is an instrument that proposes. What it produces is a proposal record, never a live version.
Adoption is an ordinary, privileged Ash action, and an adopted artefact re-earns everything on data its learner never
saw.**

1. **A proposal record, with lineage.** Every learner — an optimiser, a distillation, a rule miner, a fine-tune, a
   simulation fit — writes a proposal: the parent version, the proposed artefact, the proposer and its version, the
   instruments it used (a reflection or teacher model, with its zone), the hashes of the data splits it saw, and its
   scores, negative results included. A proposal is never a live version.
2. **Nothing learned is applied in serving.** No optimiser operation that promotes or applies an artefact is called
   outside a research job. Adoption is an ordinary Ash action by a person holding the privilege, through the same
   validate → approve → activate lifecycle as a rule revision.
3. **Adoption re-earns everything.** An adopted question version gets a new content hash, a shadow evaluation
   ([ADR 0040](0040-record-dont-recompute.md)), a calibration run on splits it never saw
   ([ADR 0041](0041-thresholds-are-dmn-earned-by-calibration.md)'s optimise split is disjoint from calibration, test
   and audit) and an approval. A distilled row or a mined rule enters the DMN or rules lifecycle as a draft. A
   fine-tuned model is a new instrument with a new digest. Fitted simulation parameters are tenant data under
   [ADR 0029](0029-process-configuration-is-tenant-data.md), used in the simulator only. Re-evaluation after adoption
   produces new observations; it never rewrites old ones.
4. **Only what the declaration leaves open may be learned.** For a question, that is instructions and per-option
   criteria ([ADR 0039](0039-judgments-are-declared-questions.md) property 6). The answer type, the option set, the
   state projection and the family are out of reach.
5. **Learners obey the zone rule.** A reflection or teacher model is a profile like any other. Sending failing passages
   to it is a flow, and a flow out of the zone is a disclosure
   ([ADR 0042](0042-in-zone-inference-leaving-the-zone-is-a-disclosure.md)).
6. **Research posture.** Every learning run has a pre-registered pass bar and kill criteria, and records negative
   results as findings. A lift is believed only on held-out data.
7. **Reviewed data is biased.** Anything fit on human verdicts includes the random audit sample, not only the middle
   band.

**Where an optimiser library fits.** `imp` is an optional development or research dependency — in a research
application or behind a development-only flag — and never a runtime dependency of the platform or of `ash_judgments`.
Its signature language is not an authoring surface: questions are declared in Ash, and any bridge runs one way, from
Ash outwards. Its `authorize:` or tool-policy hooks may only *narrow* what a research run can do — structurally
refusing any admitting, overriding or authorizing tool, or asking `Ash.can?` as a convenience — and are never a gate;
the action-layer policy stays the single gate ([thesis 5](../manifesto/05-agents-are-users.md)). Audit comes from the
platform's event log, never from a library's in-memory events. Recursive-model code execution stays out of the
compliance path entirely ([ADR 0044](0044-documents-are-addressed-atoms-evidence-is-an-assertion.md)).

## Does it consume ActorContext?

**For proposing, no; for adopting, yes.** Proposing is a research job with no grant: it runs as a development process,
or as the `system` actor writing a proposal row, and a proposal changes nothing a request can see. Adopting is an
approval and an activation — privileged actions on question versions, decision configuration or rule revisions,
resolved through the union of grants in `ActorContext` like any other write. The automation principal of
[ADR 0043](0043-automation-authority-is-a-grant.md) holds no privilege to adopt.

## Consequences

**What this makes easy.** Searching over wording is cheap, because local metric calls are nearly free, and every
candidate that was tried is on record with its score. "Where did this wording come from?" is a lineage query. A bad
adoption is a rollback to the parent version, which still exists.

**What it makes hard.** Every lift has to be proven on held-out data, so the labelled set grows by the optimise split
for every family that is optimised. Learning is as slow to reach production as a rule change, on purpose. A one-day-old,
experimental dependency is acceptable only because it never runs in serving.

**What it forecloses.** Self-modifying questions. Autonomous prompt drift. An optimiser that commits its own result.
Reviewer habit becoming policy without anyone approving it.

## Reversal

Proposals are rows. Deleting the proposal resource and the research job removes the path; adopted versions stay
ordinary versions with their lineage fields, and nothing already approved changes. Removing the optional optimiser
dependency removes one research application or development flag.
