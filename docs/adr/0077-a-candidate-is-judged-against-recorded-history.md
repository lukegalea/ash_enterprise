# ADR 0077 — A candidate is judged against recorded history

- **Status:** accepted, not built (2026-11-18)
- **Date:** 2026-11-18
- **Related:** [ADR 0067](0067-a-document-is-a-pure-function-of-recorded-inputs.md) (a document is a pure function of
  recorded inputs), [ADR 0068](0068-paper-separates-schema-layout-theme-and-wording.md) (the four axes, block
  read-back), [ADR 0028](0028-decisions-are-dmn.md) (decisions are DMN),
  [ADR 0024](0024-audit-retention-and-erasure.md) (erasure by crypto-shredding),
  [ADR 0076](0076-what-to-ask-is-what-a-requirement-cannot-yet-decide.md) (what to ask), and, as an analogy only,
  [ADR 0058](0058-agent-quality-and-releases.md) (a release is gated on deterministic runs)

## Context

A tenant changes two things about its documents without a deploy
([ADR 0068](0068-paper-separates-schema-layout-theme-and-wording.md)): the wording, as versioned clauses, and the
decision tables that choose which clauses and requirements a document carries. Both are drafted by one person and
admitted, or published, by a second. The second person is shown a diff of the text or of the table, and a diff answers
the wrong question. It says what changed in the definition. It does not say what the change does to documents: which
ones would read differently, which would gain or lose a clause, which could no longer be issued at all.

The documents already issued are a corpus of real cases, and the record makes them usable as one. Verified on
2026-11-18:

- **Issued documents can be re-rendered exactly.** ADR 0067 freezes a document's payload and typed facts, pins every
  definition by hash, and keeps the output digest. Within one pinned engine and font set a re-render is digest-equal.
- **Documents compare per block.** ADR 0068 (decision 8) reads a render back block by block, with three outcomes
  (passed, failed, unmeasured), and excludes page furniture.
- **Decisions can be replayed.** `AshDecisions.Replay` (public in `ash_decisions`, and in the version this repository
  locks) re-runs recorded `Evaluation` inputs against a candidate version. It first re-runs each case against the
  version it was recorded under, and a case that does not reproduce is reported `unreproducible` and never compared.
  It reads as the caller, through the host's read policies.
- **The shape has a precedent.** [ADR 0058](0058-agent-quality-and-releases.md) gates an agent release on
  deterministic suite runs over exactly the candidate, before a second person approves it. That is an analogy, not
  shared machinery: there the cases are a written suite, here they are the record of what was issued.

## Decision

**Before a second person admits a wording version or publishes a decision-table version, the candidate's effect on
documents already issued is measured. The admission rests on a stored report keyed to the candidate's content hash,
and it is refused unless that report is complete and has no failed case.**

1. **Measured before the second person decides.** A person runs the measurement as an action on the candidate.
   Nothing measures on read. The admit or publish action carries a validation that reads the stored report. It is a
   validation of that action, never a `forbid_if` on rows.
2. **Keyed to the candidate's content hash.** The report records the content hash it measured. A report for any
   other hash is stale and refuses: editing a draft after measuring it invalidates the measurement.
3. **A baseline control on every case.** Each case is first reproduced with what it was issued with: the document is
   re-rendered with its original definitions and must reproduce its recorded output digest, and a decision case must
   reproduce its recorded answer and matched rules. A case that does not reproduce is `unreproducible`, never
   `unchanged`. That covers inputs erased with their scope, a theme no longer available at its pinned hash, a kind no
   longer issued, and a digest that differs. Only reproduced cases are compared, so every `changed` is the
   candidate's doing.
4. **What refuses.** A missing report; an errored one (the measurement could not run, including a decision replay
   that could read fewer of the tenant's evaluations than exist, which is refused rather than reported as a clean,
   smaller sample); a stale one; a malformed one; a case whose outcome is not one the report defines; and any
   `failed` case. A case fails when the candidate cannot be issued for it: the render errors, a hole cannot be filled
   from the frozen payload, read-back does not pass, or the decision errors or no longer answers.
   `unreproducible` cases are counted and shown, and do not refuse by themselves, because they say something about
   the record rather than about the candidate.
5. **Zero affected documents is a measured result.** A report with no case, or with every case `unchanged`, admits.
   An empty sample is a measurement, as long as it is not an errored one.
6. **The sample cap is always stated.** The newest issued documents are taken first, up to a cap (50 by default, 200
   at most). The report records how many were taken, the cap, and whether the cap cut the sample. There is no silent
   cap.
7. **The deterministic gate decides; a visual diff is report-only.** The gate reads the block comparison and the
   outcome counts. A rendered side-by-side, or anything else a reviewer looks at, informs the person and never
   admits or refuses. A changed block outside the candidate's own, a moved page count or changed page furniture is
   flagged as collateral in the report, for the person to judge.
8. **Each kind of candidate is measured against the history that applies to it.**
   - **A wording version** is measured against issued documents whose snapshot pins that clause, in its locale. Each
     is re-rendered from its frozen inputs with only that clause swapped, and compared block by block with the
     original. Outcomes: `changed`, `unchanged`, `unreproducible`, `failed`.
   - **A decision-table version** is measured by replaying its recorded evaluations with `AshDecisions.Replay`, and
     each case is mapped back to the document it decided. Nothing is re-rendered. Outcomes: the document would gain
     the clause, lose it, keep the same answer for a different reason, or is `unchanged`, `unreproducible` or
     `failed`.
   - **A layout** is code ([ADR 0068](0068-paper-separates-schema-layout-theme-and-wording.md), decision 2), so it is
     measured against fixtures, never the database, by a mix task (`mix paper.impact`) that prints the same report
     and exits non-zero on a failed case. A layout change is decided in code review.
9. **The report is stored on the candidate, as data.** It is JSON on the candidate row: the candidate's identity and
   content hash, when it was measured, any error, counts per outcome (every outcome present, zero-filled), the
   collateral count, the cases and the sample. Each case's document text (its title, each changed block's before and
   after text, a failure's detail) is sealed under that document's erasure scope
   ([ADR 0024](0024-audit-retention-and-erasure.md)). Shredding a person's scope removes their text from every report,
   and the counts and outcomes stay.

## Does it consume ActorContext?

Yes, through ordinary actions. Measuring is an update on the candidate. Admitting and publishing are a second
person's acts: the person who drafted a version may not admit it. All three are authorized by the usual grants on the
candidate's resource. A decision replay reads evaluations and versions as the measuring person, through the host's
read policies, so someone who may not read a decision's evaluations measures nothing, and the measurement errors.

Re-rendering is wider. A person measuring wording usually holds no grant on the tenant's other documents, so the issued
documents are read inside the tenant by the measurement itself, bounded to documents that carry the candidate's clause.
The grant to run the measurement is the authority for that read. The report then shows the measuring person the changed
blocks' text from documents they could not otherwise read. That is a disclosure and is stated as one: a host that
cannot accept it grants the measure action only to people who may already read the tenant's issued documents.

## Consequences

- The second person decides on what the change does, not only on what it says, and cannot admit a version that would
  stop any sampled document from being issued.
- A clean report is cheap to trust: every case either reproduced and was compared, or is counted as unreproducible.
- Measurement re-renders up to the cap of documents, which takes seconds. It runs before the write's transaction
  opens and holds no lock.
- A sample is a sample. Documents beyond the cap are not measured, and the report says so. Raising the cap is a
  per-measurement option, bounded at 200.
- Unreproducible cases grow with erasure and with engine or font changes (ADR 0067, decision 6). A tenant with many
  unreproducible cases has little history to measure against, and the report shows it.
- Collateral is reported and does not gate. A person can admit a clause that moves another block, having been shown
  it.
- Reports hold document text, sealed per scope, so a candidate row is as sensitive as the documents it measured.

## Reversal

Dropping the gate is removing one validation from the admit and publish actions. The measurement and its stored
reports can stay as advice. Making the visual diff gate (decision 7) would mean accepting a pixel comparison that a
theme change or a font hint can move, so it would need its own tolerance rules first. Measuring every document rather
than a sample means removing the cap and moving the measurement into a background job with progress, because a long
measurement cannot run while the request waits. Reports already stored stay readable either way: they are data on
the candidate, and the sealed text in them follows the erasure scopes it was sealed under.
