# ADR 0050 — The subject-state digest is the third axis: evidence currency, kept on the fact row

- **Status:** accepted (ruling 2026-10-09; C1+C2 ACCEPTED, no normative amended)
- **Date:** 2026-10-09

## Context

Luke's challenge: find a more elegant embrace of RFC v2 rather than holding onto v1 legacy —
maybe `subject_state_digest` is required, but push hard on it. The memo
(`phase4-digest-vs-v2-plan.md`, programme repo, cited under Sources)
verified eight load-bearing uses (stale-proof detection, the tri-state unknown partition,
provable-only freshness, materialiser idempotency identity, correction-ledger integrity,
provenance pins, replay determinism, erasure survival) and exhausted every v2-native habitat:
deletion, read-through from observations, read-time projection rebuild, subject-side periods,
and the stored fact-row digest. Only the last survives the frozen normatives.

The decisive reframe: AST-146's two-axes correction (record validity ≠ domain validity) has a
corollary — **evidence currency is a third axis, content-borne not time-borne**. A digest
comparison answers "has the projection the question saw changed?" with no clock: robust to
backdating, clock skew, replay ordering, and the ambiguity of *which* instant. Expressing a
content axis as periods repeats the original `valid_until`→period conflation in mirror image.

**Correction 1 affirmed, now on legal grounds** (the earlier defense was physical — period-FKs
to arbitrary subjects are impossible): §7.4 n.2 (staleness is a join, not a model call),
n.3 (the set evaluator reads the facts table only, never observations for membership), and Q20
(staleness granularity is the state projection's digest, not any field) **jointly pin** a stored
projection digest onto the fact row. Any alternative habitat rewrites at least one frozen
normative or settled question, which the ratified gate forbids.

**The counterfactual was exhausted** (memo §7): amending n.2 loses erasure robustness (the
envelope-class digest survives payload erasure; a rebuild cannot run on erased state and
silently degrades stale facts to permanently fresh) and imports clock-choice semantics — net
loss. Amending n.3 buys the same guarantee C1 buys with one S-size write-path assertion, by
taxing every membership read with a permanent join to the highest-volume table — net loss.
Amending Q20 manufactures `unknown`s on irrelevant edits (signal collapse) and still fails
structurally, because not every subject can be temporal — net loss, twice over. The freeze was
worth testing; it is not why the alternatives fail.

## Decision

Keep `subject_state_digest` as per-period evidence on the fact row — **the content axis, not v1
legacy** — and land the elegance push as two mechanism refinements:

1. **C1 (mandatory, accepted):** the materialiser's evidence assertion — opt-in
   `evidence_observation_id`; a caller-side, pre-transaction read of the predicate-matched
   observation asserts `subject_state_digest == input_hash`, raising the named error
   `AshJudgments.Facts.Errors.EvidenceMismatch` on mismatch. Landed ash_judgments `aeebd86`
   (P4-S1). Closes the copy-gap by construction; deterministic on replay.
2. **C2 (commended, host-side, permissive):** hosts MAY periodize the per-(subject, question)
   current-digest table; the `current_digests` read contract is unchanged and the system gains
   as-of staleness, which the mutable-pointer shape cannot express. Reference implementation
   landed vpm_poc `a950a4e` (P4-S2). The genuine v1 legacy was the host's mutable
   current-digest pointer — and v2's embrace lands there, where it belonged all along.

The queued RFC wording (C1's additive mechanism note, C2's MAY-sentence) is parked in
[`docs/rfc/errata-queue-v2.md`](../rfc/errata-queue-v2.md). **RFC v2 stays byte-frozen**; the
entries apply only in a future revision cycle, under Appendix B's change→justification
discipline.

## Does it consume ActorContext?

No. The digest is content-derived evidence state with no actor in its semantics: the assertion
reads an immutable observation by primary key, and staleness is a join. Grade floors (the
actor-adjacent part of the fact contract) are §7.4's own normative and are unchanged.

## Consequences

- The three-axis model is now doctrine: **record validity** (`valid_at`, the period), **domain
  validity** (`valid_until`/`expired?`), **evidence currency** (`subject_state_digest`) — each
  with its own mechanism, none reducible to another.
- Staleness stays cheap and provable (n.2), the set evaluator stays table-local (n.3), and the
  stale signal stays projection-precise (Q20) — all verbatim, with stronger write-path
  integrity (C1) and an as-of staleness capability on hosts that want it (C2).
- ADR 0049's correction #1 stands with better grounds: the as-of-join emergent play supplements
  staleness checking; it does not replace it.
- The errata queue becomes the standing pattern for post-freeze findings: park, with Appendix-B
  wording, until a revision opens.

## Reversal

Reversal means amending a frozen normative, and the memo priced each exit: amend n.2 to unlock
as-of-rebuild staleness (subsumed by C2, cheaper — and it breaks erasure survival); amend n.3 to
unlock read-through derivation (parked in the errata queue as the shape to revisit *if* n.3 ever
opens); amend Q20 to unlock subject-side periods (the amendment doesn't even purchase its
mechanism — not all subjects can be temporal). C1 reverts by dropping the assertion; C2 by
dropping periods (host-local). None of these is planned; all are recorded so a future reader
re-litigating the digest finds the exhaustion, not just the verdict.

## Sources

- `system-one-program/research/phase4-digest-vs-v2-plan.md` — the decision memo and the §7
  counterfactual (ruling inputs and outcome).
- `system-one-program/research/phase4-facts-swap-design.md` — §2 contract surface, §3 C1 spec,
  §4 C2 spec, §9 slice plan.
- `docs/rfc/judgment-record-v2.md` — the frozen v2 (2026-10-08): §4.2, §5.4, §5.7, §7.2–7.4,
  §10, §13 Q20, Appendix B.
