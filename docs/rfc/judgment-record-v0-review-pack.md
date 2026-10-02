# judgment-record-v0 — review pack

Review pack for the v0 freeze (Luke, 2026-10-02). The record itself: judgment-record-v0.md, byte-frozen (sha256 70eb8192…f160).

| | |
|---|---|
| **Freeze** | "Accepted - v0 frozen" 2026-10-02 14:37 UTC; S1-58 fold-in approved 14:39 UTC, present as §7.4 (AC-6 closed). |
| **Executable half** | `priv/judgment_record/schema.json` (draft 2020-12) + `AshEnterprise.JudgmentRecord` (JSV) + six synthetic CC0 fixtures under `test/fixtures/judgment_record/`. |
| **Guard rails** | Golden sha256 pins for the doc, schema and every fixture, plus the "ACCEPTED — v0 FROZEN" sentinel: `test/ash_enterprise/judgment_record_golden_test.exs`. |

## Decisions made

- **Q3 — the hashed object is closed.** `question_hash` digests exactly `{answer_type, criteria, instructions, options, state_contract, version}`; `family` (Q3) and lineage are outside the hash.
- **Q4 — full digests.** Every digest this RFC defines is `sha256:` + 64 lower hex (256 bits), never truncated; digests copied from elsewhere keep their source format — a model digest is bare hex as the runtime reports it.
- **Q7 — digests come over HTTP; answered 2026-10-02 by the S1-21 live run.** The profile resolver takes the model digest at call time from Ollaya `/api/ps` (fallback `/api/tags`); the decide reply carries the name only.
- **Q6/Q8 — corollaries of Q7.** Runtime version belongs in the cache key (it varies across a routed fleet); `/api/ps`'s device field feeds accelerator flagging for free.
- **Q9 — a noul has no collapsed value.** `value: null` with a derived two-way distribution, so every decision answer has one shape.
- **Q11 — `omitted`, not `unknown`** (settled 2026-09-28). "No fact written" is an admission value; `unknown` is an ash_rules outcome, and the word is never reused across layers (ADR 0038).
- **Q14 — retrieval is provenance only.** The `{embedder_profile, embedder_digest, index_version}` block is not in the cache key and is not part of the verdict's identity in v0.
- **Q19 — one fact per predicate and scope, carrying `admission_grade`** (`person` | `grant`); each consumer states the minimum grade it accepts. (Numbered SYNTHESIS §7 Q13 on the ticket.)
- **AC-6 — the freeze is closed**: acceptance + S1-58 fold-in, 2026-10-02.
- The remaining §13 items carry v0's proposed positions (Q1 `state_contract`, Q2 scheme proposal, Q5 shortest-round-trip, Q10, Q12, Q15–Q18, Q20–Q22); they are visible in the schema's `$comment`s and listed below as deferred, not silently dropped.

## Questions deferred

Still open from §13, worth Luke's eye:

- **Q2** — proposing `judgment:` back to the semantic-manifest RFC alongside `dmn:`/`bpmn:` (with E5).
- **Q5** — shortest-round-trip vs a declared per-family precision. At the extremes shortest-round-trip yields scientific notation, which the v0 schema's positional decimal pattern would reject — a deliberate tightening to revisit in v1.
- **Q8** — CPU-when-calibrated-on-GPU: flagged everywhere, refused for `admit`?
- **Q10** — `recorded_at` on replay: `replay_non_input_attribute_changes` vs explicit input (implementer to confirm against AshEvents).
- **Q13** — must-record failure semantics: fail closed (confirm).
- **Q15** — the evidence assertion: on the observation, or its own `ash_evidence` record?
- **Q16 / Q17** — question-record materialisation at activation; instrument profiles as append-only records. Both not in v0.
- **Q18** — jurisdiction codes: ISO 3166-2 proposed; the zone record owns the code (examples use the placeholder `EX-1`).
- **Q20–Q22** — staleness granularity (projection digest, not any field); one host facts table; standing-query membership changes as ordinary platform events.

Deferred from the envelope's own questions:

- **E3** — `policy_decision_ids` for reads: deferred to AST-9; judgment records are all writes, so the write-path capture covers them.
- **E6** — retention classes are defined (§10); the mechanism (time partitioning, tombstone job) is deferred to CORE-LEDGER.

Carried from the W2 landing (public landing of 2026-10-02) as v1 items:

- **Layout** — §15 named `docs/rfc/fixtures/judgment/`; the schema and fixtures landed at `priv/judgment_record/` and `test/fixtures/judgment_record/` because the validator reads the schema at a compile-time priv path. Deliberate; a move is two lines.
- **wire_question_hash** — §3.3 says "recorded on every observation", §5.2's requirement column says "decision rung". Resolved as: key always required, value nullable, non-null required at the decision rung.
- **§7–§8 records are not schema'd yet** — banding, admission, human verdict, calibration run and band-table certification land with the ledger work (CORE-LEDGER, AST-85 onward). The admission `result` vocabulary is the only piece schema'd so far (`$defs/admission_result`).

## 16. Diff against seams §3.3 (AC-3)

| seams §3.3 field | Here | Note |
|---|---|---|
| `question_id`, `question_hash`, `question_version`, `family` | §5.2 question block | Plus `wire_question_hash`, `question_set_hash` |
| `subject_type` / `subject_id` | §5.4 | Also inside `state_ref` |
| `rule_id`, `predicate_id` | §5.4 `rule_ref` | Plus `bundle_hash` |
| `chunk_id` | §5.4 `candidate_atom_ids` | Renamed: atoms, not chunks (ADR 0044) |
| `document_hash` | §5.4 `document_version_hash` | |
| `state_hash` | §5.4 `input_hash` (= envelope `input_digest`) | |
| `state` | §5.4 `state`, payload class | Encryption deferred in-zone |
| `answer`, `value`, `probabilities`, `confidence` | §5.5 | `probabilities` → `distribution`, decimal strings; the whole answer map is not stored twice |
| `model_spec`, `model_version` | §5.3 `model_spec_requested`, `model_reported` | Plus `model_digest`, `runtime`, `runtime_version`, `accelerator` |
| `profile` | §5.3 | |
| `residency` | **Dropped** | Derived from zones (ADR 0042); replaced by `zone_id`, `jurisdiction`, `data_class`, `residency_restriction` |
| `usage`, `latency_us` | §5.6 | Request-scoped |
| `cache_key` | §4.4, §5.6 | Wire question hash, runtime version and zone added |
| `correlation_id` | envelope core | |
| `organization_id` (tenant) | envelope `tenant_id` | |
| `band`, `band_table_ref` | **Moved** to the banding record, §7.1 | Banding is separate and append-only (ticket normative rule) |
| (new) region | §5.4 `jurisdiction` + `zone_id` | Ticket update: region derives from the zone |
| (new) mode | §5.6 | `live | shadow | calibration | eval`; replay and cache hits write nothing |
| (new) wire schema hash, raw reply, grammar runtime | §5.3, §5.5 | ADR 0046 |
| (new) raw log-probs | §5.5 `logprobs`, payload class | Where the runtime returns them |
| (new) actor and grant | §5.2 | `automation_principal`, `grant_ref` |
| `HumanVerdict` | §7.3 | |

## Reading order

1. [judgment-record-v0.md](judgment-record-v0.md) — the contract, frozen.
2. `priv/judgment_record/schema.json` — the executable half of §3–§5.
3. `test/fixtures/judgment_record/` — synthetic golden records (CC0) and their provenance README.
4. `AshEnterprise.JudgmentRecord` — the validator; `test/ash_enterprise/judgment_record_test.exs` and `judgment_record_golden_test.exs` — the gates.
