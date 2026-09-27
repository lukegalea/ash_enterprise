# ADR 0041 — Thresholds are DMN, earned by calibration

- **Status:** proposed
- **Date:** 2026-09-27

## Context

An observation carries a probability. Something has to turn "0.93 that this passage supports the predicate" into
*admit*, *send to a person*, or *write nothing*. Wherever that line lives, it is policy: moving it changes which facts
exist and therefore which subjects are compliant, with no rule text changing.

The facts, verified on 2026-09-27:

- **`ash_rules` cannot threshold a probability.** Its only predicates are `has/3` and `neg/3` under strict equality,
  and fact values are scalars. That is a property worth keeping: the rules layer stays crisp.
- **DMN can.** `ash_decisions` evaluates DMN tables under FEEL, which converts floats to decimals, so a unary test such
  as `>= 0.92` works in a cell. Definitions are immutable once published and keyed by content hash; process and decision
  configuration is tenant data defaulting to a platform baseline ([ADR 0029](0029-process-configuration-is-tenant-data.md)).
- **Two things band tables need are built but not here.** `ash_decisions` main gained a publish-time overlap and
  completeness verifier (2026-09-20) and matched-rule recording (2026-09-23). This repository's lock predates both
  (2026-09-04), so here, today, [thesis 7 §3](../manifesto/07-what-we-do-not-have.md#3-approval-workflows--maker-checker)
  is still accurate: `Evaluation.matched_rule_ids` is always `[]`, and a `UNIQUE` table with overlapping rows publishes.
  A band table that cannot say which band fired, or whose bands overlap, is not auditable.
- **The vendor accuracy figures are not ours to plan on.** The figures in circulation — 0.766 for `laya:typed-decisions`,
  0.727 for Jev 1.13, 0.591 for `decider:2b` on a "typed-decisions" benchmark — are all sourced through Ollaya's
  comparison pages, not a benchmark published by the vendor or anyone independent. They say nothing about any
  particular question family.
- **The statistical basis exists.** Conformal selective prediction with cost-aware deferral (*Scientific Reports*,
  February 2026, on clinical triage under distribution shift) gives set-valued predictions with finite-sample coverage
  guarantees and defers low-confidence cases — which is the formal statement of an auto-pass / escalate / auto-fail
  band. PolicyGuard (arXiv 2606.32004, 2026-06-30) is real prior art for the neuro-symbolic split of "the model grounds
  atomic facts, deterministic code evaluates the rules". The "DMN and machine learning loop" framing used in this
  project's own design notes is our synthesis, not a named pattern in the literature.

## Decision

**Thresholds are band tables in `ash_decisions`: versioned, content-hashed DMN definitions, per question family, and
where needed per tenant risk tier and per region. A band table may not publish for a family without a calibration run
that supports it. Probabilities stop at the band table.**

**The band table.** Its inputs are the flattened answer (`p_supports`, `p_contradicts`, the confidence, the family,
the tenant's risk tier, the region); its output is an admission — `admit`, `review`, or `omit` — and, for `admit`, the
fact value. Its matched row is the recorded reason. The judgments package provides the bridge that flattens an answer
struct into DMN inputs; it provides nothing that evaluates them.

**Thresholds are asymmetric.** The dangerous error is a false *supports*, because it manufactures a compliant outcome
from thin evidence; a false *contradicts* costs a reviewer a look. So the *admit-supports* band sits high, the
*contradicts* band routes to a human rather than to automatic failure, and any family whose consequence is severe has
no automatic band at all. Retrieval is tuned for recall and admission for precision; the two are measured separately.

**Probabilities stop here.** What leaves the band table is a crisp fact or no fact. `review` opens a human task and
writes nothing; `omit` writes nothing. A predicate declared `missing: :unknown` therefore evaluates to `unknown`, and
the rules lattice's own guarantee — `unknown` never collapses to compliant — holds without any rule knowing a model was
involved.

**Calibration earns the table.** A calibration run is recorded per `(family, model digest, evaluation-set hash)`:
reliability bins, expected calibration error, Brier score, per-class precision and recall at each candidate threshold,
selective accuracy and coverage, and the number of labelled items. A run produces a *proposed* band-table version; it
does not activate one. The publish-time verifier — a hook on `ash_decisions` publication, the same shape as the process
engine's `DecisionResolver.exists?/1` check — refuses a band table whose family has no calibration run for the model
digest it names, or whose run is below the family's minimum n.

**Activation is a lifecycle act.** Publishing is not activating. A band table activates through the approval lifecycle
the compliance control plane already uses for rule revisions (validate → approve → activate, with an approver and an
effective date). A model upgrade is a new calibration run and a new band-table version, evaluated in shadow mode
([ADR 0040](0040-record-dont-recompute.md)) before it activates.

**Tenants tailor within bounds.** A tenant's risk tier may *raise* a threshold or remove an automatic band; it may not
lower one below the platform baseline. The baseline-and-fork mechanics are ADR 0029's.

**Audit sampling is mandatory.** A declared fraction of automatically admitted facts is routed to human review at
random, per family, because the reviewed set is otherwise only the middle band and every calibration built on it
inherits that selection bias.

**Pending, and marked so:**

- the minimum n per family, and the evaluation-set design (owner, labelling protocol, hard-negative taxonomy);
- which families, if any, get an automatic band at all — the recommendation is *supports* only, at very high
  probability, for low-consequence families; a *contradicts* result routes to a human at any confidence, so there is no
  automatic failure at all; and a suggestion never lowers a human entry;
- whether the approver of a band table is the business owner of the decision or the compliance owner of the rule. The
  recommendation is DMN as the home with the compliance lifecycle as the approval.

**Entry gate.** No band table is built in this repository before the dependency bump that brings `ash_decisions`'
overlap verifier and matched-rule recording into the lock.

## Does it consume ActorContext?

**For publishing and activating, yes; for evaluating, no — by design.** Publishing a band table and approving its
activation are actions on tenant decision configuration, gated by `(role, privilege, depth)` grants like the rest of
ADR 0029's surface. Evaluation of a band table is a pure function of its inputs and the definition hash; it takes no
actor and consults no grant, which is exactly the property that makes its result reproducible. Who may *act* on its
output is [ADR 0043](0043-automation-authority-is-a-grant.md).

## Consequences

**What this makes easy.** "Why was this fact admitted?" has a complete answer: this observation, at this probability,
matched this row of this band-table version, calibrated by this run, approved by this person, effective from this date.
Tightening automation is publishing a stricter table. Comparing two models is comparing two calibration runs on the
same evaluation set.

**What it makes hard.** Every family needs labelled data before it can have an automatic band, and labelling is the
expensive part of the whole programme. Band tables multiply by family, tier and region. And a model upgrade is no
longer a configuration change; it is a recalibration and an approval.

**What it forecloses.** Thresholds in application configuration, tool metadata or code. Probabilities inside
`ash_rules`. A global "confidence above 0.9" rule assumed to mean the same thing for every question. Planning against
vendor-reported accuracy.

## Reversal

Band tables are ordinary DMN definitions and the verifier is one publish hook, so the reversal is removing the hook and
retiring the tables. Without band tables, every observation routes to review — the human lane still works, and nothing
already admitted changes. Moving thresholds into `ash_rules` instead would need numeric comparison predicates the rules
layer does not have, which is why that alternative is recorded here rather than taken.
