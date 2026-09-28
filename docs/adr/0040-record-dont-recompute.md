# ADR 0040 — Record, don't recompute

- **Status:** proposed
- **Date:** 2026-09-27
- **Amended:** 2026-09-28 — rows carry zone and data class; generative observations record their wire schema; the
  state-encryption deferral and its trigger
- **Amended 2026-09-28 (operator answers):** rows carry the source data's residency restriction; the alias rule is
  stated for in-zone model tags, since the hosted model is never an instrument

## Context

The platform makes a promise about determinism, and it is worth being precise about which one. There are two:

- **Determinism of evaluation** — the same inputs give the same output every time the computation runs. `ash_rules` has
  it by construction. A System One model does not: not across runtime versions, hardware, batching or model tags.
- **Determinism of record** — what was decided, from which inputs, by which version, is immutable and reconstructible.
  That is what an auditor needs, and it is what the event log provides.

The platform promises the second. [ADR 0035](0035-compliance-is-projected-from-events.md) states why the distinction
bites: a replayed answer that disagrees with the original is worse than no answer, because the trail would then be
lying about why a decision was made.

The facts, verified on 2026-09-27:

- **`AshEvents` wraps only create, update and destroy.** There is no generic-action wrapper, so an `evaluate` action is
  never audited on its own. Audit reaches a judgment only if a create action on a platform resource records it.
- **Replay runs change bodies.** During AshEvents replay a change module's `change/3` still executes; only its hooks
  (`before_action`, `after_action` and so on) are stripped, unless allowlisted. A create action that called the model
  from `change/3` would call it again on replay, and rewrite history with a different answer.
- **Projectors rebuild from event 0** (`ash_events_projections`' rebuilder), and time-travel and verify operations
  already answer "as of" questions over the log.
- **Tags move.** A runtime's model tags and `-latest`-style aliases point at whatever is current; only a digest pins a
  model. `AshAi.Actions.Result` reports the versioned id behind an alias.
- **`req_llm` ships a fixture step** for tests; it is not a production replay mechanism.

## Decision

**A model answer is an observation. It is recorded once, with full provenance, and everything downstream consumes the
record. Replay never re-runs inference; re-inference is a new observation.**

**The ledger.** Judgments are persisted by a create action on a resource the *host* defines on
`AshEnterprise.Platform.Resource`, from fragments the judgments package provides — so audit, tenancy, correlation,
soft delete and policies arrive by inheritance ([thesis 4](../manifesto/04-batteries-are-inherited.md)) rather than by
the package re-implementing them. Opting a judgment family out of audit for volume is explicit and local, never silent.
A row carries, at least:

- the question's id, content hash, version and family;
- the subject, and for evidence work the rule, predicate, atom and document-version references;
- a hash of the state sent, and the state itself — whether it is retained encrypted at rest, or not retained at all,
  is a proposal pending the erasure decision below, not yet decided;
- the answer, value, distribution and confidence;
- the instrument: profile, zone, model spec, **resolved model digest and runtime version**;
- for a generative observation, the hash of the exact wire schema, the grammar-capable runtime and its version, and
  the raw reply before the Ash cast ([ADR 0046](0046-the-declaration-is-the-output-contract.md));
- usage, latency, cache key, correlation id, tenant, **zone, data class and the source data's residency restriction**
  (the region, or jurisdiction, is the zone's — [ADR 0042](0042-in-zone-inference-leaving-the-zone-is-a-disclosure.md));
- the band and the band-table version that classified it, once it has been banded.

A human verdict on a judgment is a separate, audited create that references it, carrying the question, the state
reference, the model's answer and version, and the human's answer. Those rows are the evaluation corpus.

**The replay-safe create.** The ledger's create action **accepts the answer as an input.** The instrument is called
before the transaction — in the evaluate action, a `before_transaction` hook, or an Oban worker — and its result is
passed in. Nothing in a change body calls a model, so replay reconstructs the row from the recorded input and never
reaches the instrument.

**Three modes, declared per call site:**

| Mode | Behaviour | Used for |
|---|---|---|
| **cache** (default) | Look up `sha256(model digest ‖ question hash ‖ canonical state)` in the ledger within the family's TTL; call only on a miss | ordinary operation |
| **replay** | Answer only from the ledger; a miss is an error, never a call | compliance re-evaluation, audit packs, cold-clone demos |
| **shadow** | Call a candidate instrument, record its answer against the current one, change no band | model upgrades ([ADR 0041](0041-thresholds-are-dmn-earned-by-calibration.md)) |

**The instrument is part of the verdict's identity.** A verdict is a function of the rule bundle hash, the question-set
hash, the model digest and runtime version (and, for a generative rung, the wire-schema hash), the band-table version,
the document hash, and the parser and atomiser versions. A model upgrade is therefore a rule change and travels the
rule-change lifecycle: shadow evaluation against the labelled set, approval, an effective date, and an explicit plan for
which prior verdicts it invalidates. **A floating alias is forbidden on any path that feeds an admitted fact**; the
ledger records the digest, and a profile that cannot report one cannot feed admission.

**Must-record versus best-effort** is declared per family. A judgment that can become a fact fails closed: no ledger
row, no fact, `unknown`. A generative extraction that can become a fact is must-record, like any other. Advisory
tooling judgments may be best-effort.

**The compliance evaluation's `fact_snapshot_hash` covers the ledger ids** that produced its facts, so an evaluation
can be proved to have used exactly those observations.

### Erasure versus replay — pending

Replay wants the state an instrument saw; erasure ([ADR 0024](0024-audit-retention-and-erasure.md)) wants a data
subject's content gone. The **proposal**, not yet a decision: the ledger's `state` is encrypted under the same
per-subject key ADR 0024 already proposes for the audit log, and the state hash is stored in clear. Destroying the key
leaves a tombstoned row whose hash still proves *that* an answer was recorded over some state, and whose content can no
longer be read or re-sent to an instrument. Replay from the ledger keeps working, because it reads the answer, not the
state; shadow evaluation over an erased subject becomes impossible, which is the correct loss. This inherits ADR 0024's
own caveat that crypto-shredding is not erasure in the strictest reading. It is **pending** with ADR 0024 itself.

Inside a single declared zone with full-disk encryption and one operator, encrypting the ledger's `state` is
**deferred** until the first store outside the zone or the first multi-user access to the zone. The column exists from
the first migration, so turning encryption on is a data change, not a schema change.

## Does it consume ActorContext?

**Yes.** The ledger is a platform resource, so every read of it — by a reviewer, an auditor, a fact builder — goes
through the union of grants and tenant scoping like any other row. A fact builder reading the ledger inside a change is
a read in a change, which is permitted; a policy check reading it is not, and has no need to, because admitted facts
reach authorization only as materialised attributes ([ADR 0038](0038-models-observe-declarations-decide.md)). Replay
runs as the existing `replay` system actor, as every other replay does.

## Consequences

**What this makes easy.** "What did the model say about this document on the 3rd of March, and which version said it"
is a ledger query, and time-travel over projections comes free. Repeats cost nothing. Audit packs and demos can be
reproduced without an instrument running. The same row is the audit artifact, the reviewer's surface, the regression
fixture, the calibration unit and the training example.

**What it makes hard.** Storage, and sensitivity. States are small by the local model's 1,024-token limit, but they are
free text drawn from documents, which is the worst kind of personal data to accumulate. Cache TTLs have to be chosen
per family, and a stale-but-cached answer is a real failure mode that only a TTL and a digest change prevent.

**What it forecloses.** Re-scoring history silently. Using a floating tag or alias where an answer can become a fact.
Projectors or rebuilds that reach an instrument.

## Reversal

The ledger is an ordinary platform resource with one migration; dropping it is deleting the resource and the migration
and regenerating. Admitted facts that referenced ledger ids keep their values and lose their provenance link, which is
the real cost and the argument for exporting the ledger before dropping it. The modes are options on evaluate call
sites and disappear with the package.
