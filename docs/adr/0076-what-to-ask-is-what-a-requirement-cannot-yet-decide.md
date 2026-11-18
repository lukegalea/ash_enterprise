# ADR 0076 — What to ask is what a requirement cannot yet decide

- **Status:** accepted, not built (2026-11-18)
- **Date:** 2026-11-18
- **Related:** [ADR 0035](0035-compliance-is-projected-from-events.md) (rules as data, `unknown` is never compliant),
  [ADR 0038](0038-models-observe-declarations-decide.md) (models observe, declarations decide),
  [ADR 0052](0052-self-service-actions.md) (self-service actions),
  [ADR 0053](0053-subject-state-digest-third-axis.md) (the subject-state digest),
  [ADR 0067](0067-a-document-is-a-pure-function-of-recorded-inputs.md) (a document is a pure function of recorded
  inputs), [ADR 0068](0068-paper-separates-schema-layout-theme-and-wording.md) (requirements are selected by decision
  and checked against the schema's facts)

## Context

[ADR 0068](0068-paper-separates-schema-layout-theme-and-wording.md) gives a kind of document *requirements*: what must
hold before a document of that kind may be issued in a given context. Most of what a requirement reads is already in
the tenant's rows, and arrives as the typed facts frozen into the payload
([ADR 0067](0067-a-document-is-a-pure-function-of-recorded-inputs.md), decision 1). Some of it is not in any row and
only a person can supply it: that a check was made, that a condition holds, that a figure was confirmed against its
source.

The usual answer is a form per kind of document, designed by hand. A hand-designed form drifts from the rules it
serves: it asks a question no rule reads, it misses one a rule needs, or it keeps asking a question whose answer is
already on record. Nothing shows the drift until a document is issued on a missing fact, or is blocked with no
explanation.

The pieces to derive the questions instead already exist. Verified on 2026-11-18:

- **A rule says when it cannot decide.** An `ash_rules` fact schema declares, per predicate, what an absent fact means:
  `missing: false` (read as false, and reported), `missing: :no_fact` (read as false, not reported) or
  `missing: :unknown` (a rule that probes the absent fact evaluates `unknown`). `AshCompliance.status_for/2` returns
  each rule's verdict and the absent facts the evaluation probed (`missing_facts`), and it accepts a bundle passed in,
  so it evaluates a requirement without reading a tenant's active bundle.
- **Answers already have a home and a read contract.** `ash_judgments` records facts through one write path
  (`AshJudgments.Facts.Materialiser`) with a scope, an admission grade, a `valid_until` and a subject-state digest
  ([ADR 0053](0053-subject-state-digest-third-axis.md)). `AshJudgments.Query.status/4` reads a fact as `in`, `out` or
  `unknown`, and an `unknown` carries its reason: `no_fact`, `below_grade`, `stale` (the digest it was recorded under
  is not the current one) or `expired`.
- **Nothing here issues documents yet.** This repository does not depend on the rendering package, so the interview
  lands with document issue, in later changes.

## Decision

**The questions are derived, never designed: a person is asked exactly the facts that keep a requirement's verdict
`unknown`, one round at a time, and an answer is a recorded fact that is not asked for again while it still holds.**

1. **The interview is derived from `unknown` verdicts.** Before a document renders, its kind's requirement is
   evaluated over the ground facts (from the payload's typed facts) and the answers on record. A rule that is
   `unknown` names what it is waiting for, and those absences are the questions. There is no form definition to keep
   in step with the rules: change the rule and the questions change with it.
2. **Only absences declared `missing: :unknown` are asked.** An absence the schema reads as false has already decided
   its rule (as a pass or as a failure), so asking about it would change nothing the rule reports. Such a predicate
   is not answerable at all: an answer to a predicate the requirement does not declare, or declares as anything but
   `missing: :unknown`, is refused.
3. **Always-required fields stay action validations.** A value that every document of a kind needs, in every context
   (the subject's name, the issue date), is checked by the issue action's own validations and attribute constraints,
   and is never an interview question. The interview is for facts a requirement needs only in some contexts.
4. **A decision's declared inputs are checked for presence first.** A decision table that selects wording or a
   requirement (ADR 0068, decision 5) is evaluated only when every input it declares is present (an opt-in check
   planned for `ash_decisions`' evaluate, `require_inputs: :declared`). A missing input
   blocks the document and is named. It never lets the table match no rule, which would drop an outcome (a clause, a
   requirement) without anyone seeing it go.
5. **One round at a time.** A rule stops at its first `unknown`, so answering one question can expose the next. The
   interview is "the next missing facts, repeated until stable": each issue attempt evaluates once, blocks with the
   questions it found, and the next attempt, after they are answered, may ask more. A requirement with no unknown
   rules issues; one with a failed rule blocks with the failure, not a question.
6. **An answer is a person-grade fact, held under a scope and a keyed digest.** An answer is recorded as a fact at
   the person grade, in a scope the host chooses (the tenant and the period the answer is about, for example), and
   under a digest of the state it answered: an HMAC over the scope and the payload's typed facts, keyed per host.
   An unkeyed digest of a few figures can be brute-forced back to them, for the same reason as ADR 0067's decision 4.
   The answer carries a `valid_until`.
7. **Nothing is asked twice, and nothing stale is reused.** A question whose answer is current (same scope, same
   digest, unexpired, at or above the person grade) is decided by that answer and not asked, so a second document in
   the same scope over the same state reads the first answer. An answer that is stale (the state it answered has
   changed), expired, or recorded below the person grade is `unknown` again, and the question is asked again with its
   reason (`no_fact`, `stale`, `expired`, `below_grade`).
8. **Unknown or errored never reads as a pass.** A requirement that is `unknown` with nothing askable, an overall
   outcome that is neither compliant nor not applicable, or an evaluation that fails, blocks the document. What
   cannot be shown to hold is not treated as holding ([ADR 0035](0035-compliance-is-projected-from-events.md)).
9. **The library owns the derivation; the host owns the answers.** The step from a status and its bundle to the list
   of askable absences per unknown rule is generic, and its planned home is `AshCompliance.Status.questions/2` in
   `ash_compliance`. The host owns the rest: which requirement a kind carries, the scope, the digest key, the facts
   resource answers are recorded in, and the surface that shows the questions.

## Does it consume ActorContext?

Yes, and it adds nothing to it. The questions are computed from the person's own blocked documents, read through the
document resource's policies as that person. Answering is a self-service action
([ADR 0052](0052-self-service-actions.md)) that scopes itself to the actor: it takes only the document, the predicate
and the answer, re-reads the document as the person, and refuses a predicate that document did not ask about. The
scope and digest come from what the document recorded, never from input. The fact it admits names the answer row as
its admission. Only a person answers: the interview reads at the person grade, and a fact admitted from a model's
observation carries the lower grant grade ([ADR 0038](0038-models-observe-declarations-decide.md)), so a model may
propose an answer but its fact reads as `below_grade` and the question is still asked.

## Consequences

- A requirement is the one place a conditional question is defined. A rule change that needs a new fact asks for it
  on the next issue attempt, with no form to update.
- A person sees why each question is asked: never answered, the state changed since, the answer expired, or an
  answer below the person grade.
- Several rounds can be needed, and that is deliberate: asking everything a rule might need up front would ask
  questions whose answers change nothing.
- The digest makes freshness exact and coarse at once. Any change to the payload's typed facts in the scope makes
  every answer in it stale. That over-asks rather than under-asks, and it is the correct direction.
- A wrong `missing:` declaration is a wrong interview: declaring a person-only fact `missing: false` silently decides
  it as false. The fact schema is reviewed as code because of this.
- Destroying an erasure scope's key makes the digest unverifiable along with the payload, so answers about an erased
  subject cannot be matched to anything again.

## Reversal

Going back to designed forms means a form definition per document kind and a check that it covers the requirement's
`missing: :unknown` predicates. Without that check the drift returns. The recorded answers stay valid facts and need
no migration. Dropping the digest (decision 6) in favour of `valid_until` alone means accepting answers about a state
that has since changed; it is a change to the interview's read options and nothing else. If
`AshCompliance.Status.questions/2` is not built, the derivation stays in each host, which costs a copy per host and no
capability.
