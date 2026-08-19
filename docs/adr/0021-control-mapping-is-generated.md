# ADR 0021 — The compliance control map is generated from the ledger

- **Status:** accepted
- **Date:** 2026-08-19

## Context

Verified on 2026-08-19: the words "SOC 2" and "ISO 27001" appeared **nowhere** in this repository —
not in the manifesto, the ADRs, the roadmap, the README, `lib/`, or the marketing site. "GDPR"
appeared twice, both times admitting a gap.

That is a strange omission for a reference architecture whose central claim is that enterprise
cross-cutting concerns are declarable, because a good deal of what it already ships *is* the technical
prerequisite for named controls. Ownership and the policy union are CC6.1. The audit log is CC7.2.
Migration codegen with a `--check` gate is CC8.1. None of it said so, in the vocabulary the person
asking actually uses.

The obvious way to fix that is to write a compliance page. The obvious way for a compliance page to
become false is for someone to change the code and not the page — which is the same failure the
roadmap tables already solved by being generated from `docs/roadmap.json` and gated by
`mix ash_enterprise.roadmap --check` in CI.

There is also a real risk in the other direction. "SOC 2 ready" is a claim a repository cannot
substantiate about itself: certification is an auditor's judgement about policies, processes and
evidence over a six-to-twelve-month window, most of which is not code at all. Overclaiming here would
poison the honesty mechanism the rest of the site is built on, which is the most valuable thing it
has.

## Decision

**A control map, generated from the same ledger as everything else, that claims technical
prerequisites and says so in its first paragraph.**

`docs/controls.json` maps each control to the ledger questions bearing on it. Because every question
already carries a status and a `proof` path, the rendered map inherits both: a control whose questions
are all `shipped` shows the tests that prove them, and a control with an `open` question shows the
gap rather than eliding it. `mix ash_enterprise.roadmap` renders it into `docs/COMPLIANCE.md` and the
site; `--check` fails CI when they diverge.

**Frameworks covered:** SOC 2 Trust Services Criteria (CC6, CC7, CC8), ISO/IEC 27001:2022 Annex A
(A.5, A.8), and GDPR articles with a technical surface (15, 17, 30, 32).

**The disclaimer is the first thing on the page, not a footnote.** A control map is an engineering
artefact describing what the code does. It is not an assertion of compliance, it does not substitute
for an audit, and roughly half of any real control — the policy, the training, the review cadence,
the evidence that someone looked — is not in this repository at all.

## Consequences

**What this makes easy.** Answering a security questionnaire by pointing at a test. And, less
obviously, finding gaps: mapping controls to questions surfaced that "evidence of review" has no
answer here at all, which became `q38` and ADR 0025 rather than staying invisible.

**What it makes hard.** The map is only as honest as the ledger, so a wrong status is now wrong in one
more place — including a place a buyer reads. That is the intended trade: one source, gated, rather
than a document maintained separately and diverging quietly.

**What it forecloses.** Marketing the project as compliant. The disclaimer makes that awkward on
purpose.

**A standing maintenance cost.** Control identifiers move: ISO 27001 renumbered substantially in the
2022 revision, and the Trust Services Criteria have been revised more than once. The map carries the
revision it was written against, and going stale is a normal reason to update it rather than a defect.

## Does it consume ActorContext?

Not applicable — nothing runs. It is a generated document, and its only dependency is
`docs/roadmap.json`.

## Reversal

Delete `docs/controls.json`, `docs/COMPLIANCE.md`, the `controls` renderer in
`lib/mix/tasks/ash_enterprise.roadmap.ex`, and the site page. Under an hour. Nothing depends on it:
no code reads it and no test asserts on it beyond the renderer's own round-trip.
