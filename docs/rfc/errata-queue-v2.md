# RFC errata queue — judgment-record v2 (parked for the NEXT revision cycle)

| | |
|---|---|
| **Status** | **QUEUED — NOT APPLIED.** Nothing in this file amends `judgment-record-v2.md`. The frozen v2 (Luke-approved 2026-10-08) **stays byte-frozen**: until a revision cycle is opened, v2 governs exactly as frozen and this queue has no normative force. It exists so the next revision can apply these entries deliberately, under the same change→justification discipline Appendix B used for the v1→v2 edit — not ad hoc, and not by editing a frozen document in place. |
| **Work item** | Plane P4-S3 (the digest-ruling record), under the Phase-4 facts temporal swap. Siblings: P4-S1 (C1, merged ash_judgments `aeebd86`) and P4-S2 (C2 reference implementation, merged vpm_poc `a950a4e`) |
| **Provenance** | The digest ruling (Luke, 2026-10-09): C1 + C2 **ACCEPTED**, no normative amended, RFC v2 byte-frozen. Design notes: `system-one-program/research/phase4-digest-vs-v2-plan.md` (the decision memo + §7 counterfactual) and `system-one-program/research/phase4-facts-swap-design.md` (§3 C1 spec, §4 C2 spec, §2 contract surface). Decision record: ADR 0050 |
| **Gate carried** | Both entries are **mechanism notes**: §7.4 normatives 1–6 and the §7.2 rules carry verbatim; both behavioral equivalence proofs (`Set.membership ↔ Query.tri_state`, materialiser replay-equivalence) stay the acceptance line, unchanged |

## The queue

### E-1 — §7.4 additive mechanism note: the materialiser's evidence assertion (C1)

| | |
|---|---|
| **Change** | Add one implementation-note bullet to §7.4 (mechanism notes, not normatives): the materialiser, when the admission decision carries its evidence reference (`evidence_observation_id`, **opt-in**), reads the predicate-matched observation by primary key once, **caller-side and pre-transaction** — over immutable envelope-class data — and asserts `subject_state_digest == observation.input_hash`. On mismatch it raises the named error `AshJudgments.Facts.Errors.EvidenceMismatch` (`:predicate`, `:expected` = the observation's `input_hash`, `:recorded` = the fact's `subject_state_digest`) and writes nothing. A nil-or-absent reference takes the unchanged path: provable-only staleness is untouched (a fact with no digest, and a fact with no known current digest, both still read **fresh**, §7.4 n.2 verbatim). |
| **Where** | §7.4 implementation notes — one additive bullet. The §7.4 field table is untouched: `subject_state_digest` keeps its row verbatim ("the digest of the state projection the question saw") |
| **Justified by** | `phase4-digest-vs-v2-plan.md` §6 (C1, mandatory; AST-147 scope); `phase4-facts-swap-design.md` §3 (spec: deterministic on replay, not a change body, not a membership read); the digest ruling (2026-10-09, ACCEPTED) |
| **Why additive is legitimate** | It closes the copy-gap by construction: `fact.subject_state_digest` is definitionally a copy of `observation.input_hash` (§4.2 ≡ §7.4), and nothing previously enforced the copy's integrity. A write-path validation over recorded, replay-deterministic inputs *strengthens* the replay guarantee. It reads observations for evidence verification, never for set membership — §7.4 n.3's letter ("the set evaluator reads this table only") is about membership reads and is untouched. No field is removed or renamed, so §11's breaking-change rule is not triggered; per the v1→v2 precedent this is errata-class, not a version bump. |
| **Landed** | ash_judgments P4-S1, merged `aeebd86` (opt-in in the package; hosts pass the reference at cut-over; clinic-demo from day one) |

### E-2 — §7.4 permissive MAY-sentence: the host digest timeline (C2)

| | |
|---|---|
| **Change** | Add one MAY-sentence to §7.4 (host implementation latitude, not a normative): **Hosts MAY periodize the per-(subject, question) current-digest table** — keeping digest history as periods (`strategy :context`) rather than a single mutable current-digest pointer. The `current_digests` read contract is **unchanged** (digest-at-now; zero proof exposure; staleness checking untouched). Periodization adds **as-of staleness** — `digest_at(T, subject, question)` compared against a fact-period's recorded digest, answering "was this fact stale when the standing query fired?" — a capability the pointer shape structurally cannot express. |
| **Where** | §7.4 implementation notes — one permissive sentence beside the freshness machinery. §7.4 n.2 is untouched verbatim: the normative requires the host to keep each subject's current projection digest per question, updated in the same transaction as the subject's change — periodization is *shape* latitude under that requirement, and the same-transaction discipline (and the raw-SQL ban) carries to digest-period writes |
| **Justified by** | `phase4-digest-vs-v2-plan.md` §6 (C2, commended, host-side); `phase4-facts-swap-design.md` §4 (spec: read contract unchanged, `stale.ex` untouched, same-transaction discipline); the digest ruling (2026-10-09, ACCEPTED) |
| **Why permissive is legitimate** | The genuine v1 legacy in the staleness mechanism was never the fact's recorded digest — it is the host's **mutable current-digest pointer**: a stored "current", exactly the shape v2 deleted on facts (no stored `current?`, no collapsed boolean). MAY is the right modal: the normative fixes *that the digest is kept and when it is written*; how the host stores it (pointer vs periods) is mechanism, and hosts that do not need as-of staleness change nothing. |
| **Landed** | vpm_poc P4-S2, merged `a950a4e` — the reference implementation (digest periods + the as-of-staleness demonstration test); package docs carry the pattern note |

## Application discipline (for the revision opener)

1. **Both or neither.** E-1 and E-2 are one ruling (C1+C2, 2026-10-09); they are queued separately only because they land in different places in the text.
2. Both entries follow Appendix B's map shape (change → where → justified by) so the next revision's audit trail can absorb them without re-derivation.
3. Normatives 1–6 and §7.2 carry verbatim, again. The equivalence proofs re-run as the pass/fail line.
4. If n.3 is *ever* amended (no plan; the §7 counterfactual ruled it a net loss), the parked read-through candidate — derive the digest via `admission_id → observation_ids → input_hash` — is the shape to revisit (`phase4-digest-vs-v2-plan.md` §3, candidate 2). It is parked here as a pointer, not proposed.
5. Until applied: **v2 stays byte-frozen.** This queue is a parking lot, not a license.
