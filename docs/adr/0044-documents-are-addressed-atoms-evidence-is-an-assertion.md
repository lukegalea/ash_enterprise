# ADR 0044 — Documents are addressed atoms; evidence is an assertion

- **Status:** proposed
- **Date:** 2026-09-27

## Context

The motivating use for System One judgments is evidence work: does this document — a certificate of insurance, a
contract, a licence — satisfy this obligation? The tempting shape is to hand a model the document and the rule and ask
"does this comply?". That question has no typed answer, no calibrated probability, no citation and no replay. It is the
shape [ADR 0038](0038-models-observe-declarations-decide.md) exists to refuse.

The facts, verified on 2026-09-27:

- **Local instruments see very little at once.** `laya:typed-decisions` has a 1,024-token context (512 for `laya:en`);
  `decider` has 32k; hosted Jev has 64k with 32k of state. A realistic document does not fit the default local model,
  and chunking is therefore a design decision rather than a tuning parameter.
- **`ash_rules` facts are scalar triples** compared by strict equality. Provenance — which passage, which model, which
  probability — cannot ride on a fact; it has to live beside it.
- **`ash_compliance` already has an evidence record.** `EvidenceArtifact` carries a `method` constrained to the OSCAL
  assessment methods (`examine`, `interview`, `test`), a `collector` string, a content hash and a chain of custody.
  `ComplianceEvaluation` carries a `fact_snapshot_hash`.
- **The vendor's own guidance matches the split.** Its published cookbook for citation checking uses a four-way verdict
  (verified, fabricated, contradicted, unsupported) behind a confidence gate; its build guide teaches decomposing a
  judgment into atomic questions and combining them in code. PolicyGuard (arXiv 2606.32004) describes the same
  neuro-symbolic split for organizational policy review.
- **`ash_rules` never searches documents or calls models, and `ash_compliance` never parses them.** Both are stated
  package boundaries, and both are right.

## Decision

**A document is a graph of addressed atoms. A rule is compiled into atomic evidence predicates with deterministic
composition. A model's contribution is an evidence assertion over atoms, referring to them by id; it becomes a fact
only by admission.**

**Addressed atoms.** A document version is parsed once, losslessly, into atoms — sections, clauses, sentences, list
items, definitions, tables and cells — each with a stable id and its page, bounding box and character coordinates, and
with typed edges between them (`defines`, `exception_to`, `subject_to`, `references`, `table_header_of`). The
structured parse is authoritative; any Markdown or plain-text rendering is a projection of it. The parser and atomiser
versions are part of every verdict's identity ([ADR 0040](0040-record-dont-recompute.md)). Each atom has up to three
forms: the **verbatim** text, which is the only form ever shown as evidence or adjudicated; a **contextual key**
(heading path, applicable definitions, then the text), used for retrieval; and optionally a generated **proposition
key**, used for retrieval only and never quoted or judged.

**Context grows; it is not chunked permanently.** Adjudication starts from the smallest atom and adds context one
dependency at a time — lead-in, neighbours, heading, local definitions, exceptions and cross-references, document-wide
definitions — asking at each step whether the evidence is now sufficient. That is how a 1,024-token instrument reads a
long document honestly.

**The evidence contract.** An assertion records: the rule and predicate (with versions), the subject, the document
version hash, the candidate atom ids considered, the disposition (`supports`, `contradicts`, `insufficient`,
`not_applicable`), the selected and limiting atom ids, missing dimensions, the probabilities, the question hash and the
instrument. It is a ledger row. **Packets carry source ids, never quotations**: the application resolves ids to text
and coordinates, so a model cannot fabricate a quote, and the packet replays.

**Dual-hypothesis retrieval.** Every predicate compiles to a hypothesis and a counter-hypothesis, plus its typed
dimensions. Retrieval runs separately for supporting evidence, contradicting evidence, exceptions and each missing
dimension — lexical and vector search first, a System One reranker over the candidates second. Contradiction is sought,
not merely noticed, because the dangerous error is a false *supports*. Amounts, dates, units, parties and modality are
checked by deterministic code, never by the model.

**Ranking is not existence; absence is not evidence.** The best-ranked passage is not proof that any passage satisfies
the predicate. "Is there any such clause?" is its own question with its own threshold. A model can report what it found;
it can never establish that nothing exists, so *not found* is `insufficient`, which admits no fact.

**Brute force is an audit sweep, not the production path.** The full rule × atom × question matrix is the upper-bound
baseline for a spike and a periodic audit of the retrieval path — if the sweep finds evidence retrieval missed, the fix
is retrieval, never a more holistic question. Production is retrieval-first.

**Extract → verify.** Where a value must be pulled out of a document (a limit, a date, a named party), a generative
model *proposes* the value and System One *verifies* it against the cited atom. Agreement is an observation; disagreement
is a pipeline-quality event routed to review. Neither is a fact until admitted.

**Assertion, then admission, then fact.** An assertion is a proposal. Admission — by band table and authorized actor
([ADR 0041](0041-thresholds-are-dmn-earned-by-calibration.md), [ADR 0043](0043-automation-authority-is-a-grant.md)) —
writes the fact the rules read, through an ordinary action. Admitted facts are immutable and superseded, never edited.
No model has a tool that writes an obligation, an assessment or an eligibility decision.

**The explanation is the evidence.** What a reviewer or auditor is shown is the packet and the rule trace: the atom text
by id and coordinates, the predicate, the recorded probability, the band-table version and matched row, the rule and
combining algorithm. A System One model gives no reasons and none is invented for it. Generated prose, if shown at all,
is labelled commentary.

**Bridge into compliance.** A model-derived evidence item enters `ash_compliance` as an `EvidenceArtifact`. The proposed
convention is `method: :examine`, `collector: "systemone:<model digest>"` and the ledger id in the chain of custody; it
is **pending**, because it decides how model-derived evidence appears in an OSCAL export. The fact builder on a guard
path *reads* admitted facts and never calls an instrument.

**Package boundary.** The mechanism — document versions, atoms, retrieval, packets, the assertion-to-admission flow and
the bridges — belongs in a public evidence package (working name `ash_evidence`, **pending**). Rule semantics, compliance
status and any domain's predicates, question wording and thresholds do not; a deployment's own rule library and
labelled data stay in that deployment.

## Does it consume ActorContext?

**Yes.** Documents, atoms, assertions and admitted facts are platform resources, so they inherit the union of grants and
tenant scoping; an atom is readable exactly when its document is. Retrieval runs as an actor — the requesting user
interactively, the automation principal in background evaluation — so a candidate set can never include atoms that
actor could not read, and a model is never shown a passage its caller was not entitled to.

## Consequences

**What this makes easy.** Every admitted fact traces to a page, a paragraph and a character range, and to the predicate,
model and band that admitted it. One packet serves six uses — audit artifact, reviewer surface, regression fixture,
calibration unit, training example, explanation — which is why the substrate is worth building even with a human in
every loop.

**What it makes hard.** Parsing, atomising and retrieval are real infrastructure with their own versions, failure modes
and evaluation. Compiling a rule into atomic predicates and counter-hypotheses is skilled work per rule, and it is where
most of the accuracy is won or lost.

**What it forecloses.** Whole-document "does this comply?" questions. Model-quoted evidence. Treating a top-ranked
passage as proof of existence.

## Reversal

The evidence package is a tier 3 dependency confined to its own resources and one host domain; removing it drops those
resources and their migrations. Admitted facts survive as facts. Predicates that depended on future assertions fall back
to `unknown` and to human entry, which is how evidence was handled before, and still works.
