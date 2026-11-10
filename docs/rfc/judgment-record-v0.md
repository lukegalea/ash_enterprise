# RFC: The judgment record, v0

| | |
|---|---|
| **Status** | **ACCEPTED — v0 FROZEN.** Luke, 2026-10-02 14:37 UTC: "Accepted - v0 frozen"; 14:39 UTC: "YES - fold S1-58 into this before freeze" — fold present as §7.4. Edits after this point go to a v1 draft, never to v0. |
| **Revision** | 3 (2026-09-28: §7.4 query-side requirements and Q19–Q22 added for ADR 0048, a judgment is a predicate over any set). Revision 2: Q11 settled as `omitted` by Luke. Revision 1: 2026-09-28, overnight programme run |
| **Work item** | Plane S1-24 (F-RFC-JUDGMENT), parent S1-4 (T-CORE). Linked: AST-9 (Lane G provenance envelope) |
| **Gate** | Freezing it is one of the entry conditions for W2/W3 (HANDOFF §3; SYNTHESIS §5, "Entry gate for W3") |
| **Target** | `ash_judgments` (ledger fragments, registry, calibration), the host ledger resource in ash_enterprise, `ash_evidence` (packets), `ash_decisions` (band tables, read-only here) |
| **Extends** | The provenance envelope (`ash_enterprise/docs/verification/provenance-envelope.md` §2.1). Reuses the semantic-manifest RFC's id grammar (§4.3), hash format (§4.4) and canonical JSON (§7.2) |
| **Grounded against** | `ash_ai` 1.1.0 and `req_llm` 1.24.0 as locked by ash_enterprise (`deps/`, read only); `ash_decisions` main `040ce6d`; ADRs 0038–0047 and thesis 8 (all *accepted, not built*, 2026-09-28); ADR 0048 (*accepted*, 2026-10-02) |
| **Where this draft lives** | The private programme repo, `rfc/S1-24-judgment-record.md`, as tonight's run asked. The ticket's final home is public `ash_enterprise/docs/rfc/judgment-record-v0.md` with a `.schema.json` and fixtures. The text contains nothing private (DEC-MOAT), so it can move unchanged once frozen (§15) |
| **Supersedes** | Nothing. When it lands publicly, the provenance-envelope doc gets the status "Superseded in part by judgment-record-v0 §3–§5" |

All examples use a synthetic veterinary clinic (the clinic-demo domain). No question wording, band values, families or
data from any real deployment appear here, by design (DEC-MOAT: question wording, band tables, calibration runs and
labelled sets are private assets).

---

## 0. Framing for reviewers

**The short version: one envelope, one judgment extension, five append-only record kinds, and a replay rule.**

System One work produces a chain of facts about facts:

```
Question (declared)      ── what was asked, at which version
   │
   ▼
Observation              ── what an instrument said, when, over which input   (immutable; law 2)
   │
   ▼
Banding                  ── which band-table row that answer fell into         (append-only; references the observation)
   │
   ▼
Admission                ── who turned it into a fact, a review task, or nothing, under which grant
   │
   ▼
Fact → rules             ── ash_rules evaluates facts; it never sees a probability

CalibrationRun ──earns──▶ BandTable (an ash_decisions definition) ──activated by──▶ a person (author of record)
HumanVerdict   ──references──▶ Observation     (the evaluation corpus)
```

Each arrow is a separate record, written by a separate action, at a separate time. Nothing is updated in place. That
separation is what the three-layer rule (ADR 0038 "Three layers of outcome, never mixed") looks like on disk.

Five things a reviewer should decide, because the rest follows from them:

1. **The observation carries its instrument identity as digests, not as names** (§5.3). A model tag or alias is never
   enough. A profile that cannot report a digest cannot feed admission (ADR 0040).
2. **The ledger's create action accepts the answer as an input** (§6). This is the AshEvents constraint: replay runs
   change bodies, so a change that called a model would call it again and rewrite history.
3. **The judgment ledger is its own table, separate from domain events** (§10, answering docs-s1 C10). Domain events
   carry summaries and ids only.
4. **State values are absent from the envelope class by default** (§5.4, §10). The record keeps a digest and a
   reference. The state itself, the raw reply and any log-probs are *payload class*: retained per zone and tenant
   policy, and erasable without breaking replay.
5. **Probabilities are decimal strings in the canonical form** (§4.3), because the semantic-manifest canonical JSON
   forbids floats and FEEL reads decimals anyway.

This RFC specifies records and rules. It does not specify code, a DSL grammar, threshold values, or anything specific
to one deployment.

---

## 1. Goals and non-goals

### 1.1 Goals

- **Reconstructibility (law 6).** Every verdict can be traced to: the rule bundle hash, the question-set hash, the
  model digest and runtime version, the band-table version, the document hash, and the parser and atomiser versions.
  For generative observations, add the wire-schema hash. Every row also carries the zone id and the data class.
- **Replay without inference (law 2).** Replay and projection rebuilds read recorded answers and never reach an
  instrument. Re-inference is a new observation.
- **Design once (AST-9).** The observation is the provenance envelope plus a judgment extension. There is no second
  envelope.
- **One record, six uses (law 12).** The same rows serve as the audit artefact, the reviewer surface, the regression
  fixture, the calibration unit, the training example and the explanation.
- **Separation of layers.** Disposition, admission and rule outcome never share a field or a record.
- **Zone and jurisdiction on every row** (law 10, ADR 0042). No row exists without a zone.

### 1.2 Non-goals for v0

- Implementation. That is CORE-LEDGER (AST-85 onward) and the host envelope build on AST-9.
- The registry DSL grammar. ADR 0039 fixes its properties; the package settles its syntax. This RFC fixes only the
  registry *key* and the fields a question record must expose (§3).
- Threshold values, minimum n per family, and which families get an automatic band. Those are ADR 0041 pending items
  and deployment data.
- Any deployment's predicates, question wording, band tables or labelled data.
- Retrieval scoring records (BM25 and vector scores, reranker scores) beyond the ids and versions that identify what
  was considered. Those belong to `ash_evidence` and are open question Q14.
- A wire format for exchanging records between installations. v0 is a storage and export contract.

---

## 2. What exists today (verified 2026-09-28 against the lock)

| Piece | Where | What it gives this RFC | What it does not give |
|---|---|---|---|
| `AshAi.Actions.Evaluate` | `deps/ash_ai/lib/ash_ai/actions/evaluate.ex:98-120` | The call. State = the action's arguments (`default_state/1`) or a `state:` override. Questions come from the return type or a runtime `questions:` option. Answers are cast with `Ash.Type.cast_input` + `apply_constraints` | Any record. A generic action is never audited by AshEvents |
| Answer types | `deps/ash_ai/lib/ash_ai/evaluate/{noul,choice,score,judgments}.ex` | `Noul{probability}`; `Choice{value, probabilities, confidence}`; `Score{value, level, probabilities, confidence}`; `Judgments` = many questions in one request | Token log-probs. No `Evidence` type yet (ADR 0039 proposes it upstream) |
| `AshAi.Actions.Result` | `deps/ash_ai/lib/ash_ai/actions/result.ex` | `model` (the runtime's reported id, e.g. the version behind an alias), `usage`, `provider_meta` | A digest. `model` is a name string |
| `req_llm` `typesafe` provider | `deps/req_llm/lib/req_llm/providers/typesafe.ex:18-45, 96-120` | `POST /v1/systemone`; per-call `base_url`; `provider_meta.raw_response` keeps the runtime's raw body; `noul` normalised to `probability` | A `TYPESAFE_BASE_URL` env read; any digest field; log-probs |
| `AshAi.Actions.Prompt` | `deps/ash_ai/lib/ash_ai/actions/prompt.ex` | The generative rung, decoded under a schema derived from the Ash return type, re-cast after | Per-call schema narrowing; string-keyed refinement-complete schema (typed-output §1.4) |
| Provenance envelope | `docs/verification/provenance-envelope.md` §2.1–§2.7 | The core struct: `semantic_id`, `definition_version`, actor fields, `input_digest`/`output_digest`/`redaction_digest`, `matched_rule_ids`, `policy_decision_ids`, `evidence_ids`, correlation and trace ids, the retention classes | Model, instrument, zone or answer fields. It is "Design — for review" and unbuilt |
| AshEvents wrappers | `deps/ash_events/lib/events/{create,update,destroy}_action_wrapper.ex`, `replay_change_wrapper.ex:9-40` | Audit of create/update/destroy. On replay, change *hooks* are stripped and change *bodies* run | Generic-action audit |
| `ash_decisions` | `lib/ash_decisions/resources/definition.ex` (`key`, `version`, `status`, `content_hash`), `evaluation.ex` (`definition_key`, `definition_version`, `matched_rule_ids`, `inputs`, `outputs`, `correlation_id`) | The band table and a recorded evaluation of it. On main: the overlap/completeness verifier and matched-rule recording | A link to a calibration run. ash_enterprise's lock predates matched-rule recording (ADR 0041) |
| ReqLLM telemetry | `[:req_llm, :request, :start/stop]`, `[:req_llm, :token_usage]` | Latency and usage for metrics | A durable record |

---

## 3. The question registry key

### 3.1 Question id

A declared question is identified structurally, in the semantic-manifest grammar:

```
judgment:v0:<Module>#judgments/<name>
```

- `<Module>` is the resource or domain that declares the question (ADR 0039: "on the resource or domain that owns the
  subject"), as a dotted string without the `Elixir.` prefix.
- `<name>` is the question's declared name.
- Example: `judgment:v0:ClinicDemo.Scheduling.Appointment#judgments/notes_document_follow_up`.
- The id is **structural, not content-hashed**, for the reasons semantic-manifest §4.3 gives. It names the slot. The
  content lives in `question_hash`.
- A consumer that does not recognise the `judgment:` scheme treats the id as opaque (semantic-manifest §6.2).
- Proposing `judgment:` back to the semantic-manifest RFC, alongside the envelope's `dmn:` and `bpmn:`, is open
  question Q2.

The evaluate action that asks the question has its own envelope `semantic_id` in the `ash:` scheme (for example
`ash:v0:ClinicDemo.Scheduling.Appointment#actions/judge_notes`). The two ids are different on purpose: one names what
ran, the other names what was asked. A `Judgments` action asks several questions through one action.

### 3.2 Question hash (identity)

`question_hash` = digest (§4.2) of the canonical JSON (§4.3) of exactly this object:

```json
{
  "answer_type": "AshAi.Evaluate.Choice",
  "criteria": { "...": "per-option or true/false descriptions, as declared" },
  "instructions": "…as declared; a string, or the declared JSON structure…",
  "options": ["…in declaration order…"],
  "state_contract": "sha256:…",
  "version": 3
}
```

- These are ADR 0039 property 2's inputs (instructions, criteria, answer type, options, version), plus
  `state_contract`, which is **proposed** and is open question Q1.
- `state_contract` is the digest of the *declared shape* of the state projection's output (its Ash type and
  constraints rendered through the one mapping of ADR 0046 §2), not the projection's module name. A projection change
  that alters what the model can see alters the shape and mints a new question. A refactor that does not alter the
  shape does not. The hazard is a projection change that alters *content* without altering shape (for example, a
  different field feeding the same string slot). Q1 asks whether that hazard is acceptable.
- `family` is **not** in the hash. It is a calibration grouping, and moving a question between families is a
  governance act recorded on the question record, not a new question. (Q3 asks the reviewers to confirm.)
- Lineage (`parent_hash`, `proposer`, `proposer_version`, `proposal_id`) is **not** in the hash (ADR 0039 property 2;
  ADR 0047 point 1).
- For `Choice`, `options` is the ordered option list derived from the `of` enum or `one_of`. For `Score`, it is the
  ordered level list. For `Noul`, it is `[true, false]`.

### 3.3 Wire question hash (what was actually sent)

Runtime questions exist. A matrix action supplies instructions per element through `questions:`
(`evaluate.ex` "Dynamic questions"), and a `Choice` may receive a runtime subset of its options. So the declared
question and the question sent can differ.

`wire_question_hash` = digest of the canonical JSON of the exact question object sent for this question id, after
`Answer.to_question/3` (for example `{"type":"choice","instructions":…,"criteria":…}`), taken before the provider's
own normalisation. It is recorded on every observation. `question_hash` identifies the declaration;
`wire_question_hash` identifies the call. The cache key uses the wire hash (§4.4).

This is the decision-rung analogue of ADR 0046's `wire_schema_hash` for the generative rung.

### 3.4 The question record (a registry entry)

The registry is DSL, so the compiled declaration is the source of truth. The judgments package also materialises one
append-only **question record** per `(question_id, question_hash)` the first time it is activated, so the ledger can
join to a row rather than to code that may have changed since.

| Field | Type | Req | Notes |
|---|---|---|---|
| `question_id` | string | yes | §3.1 |
| `question_hash` | digest | yes | §3.2 |
| `question_version` | integer | yes | The declared `version`. Monotonic per `question_id`. Two different hashes under one version is a registry error at compile time |
| `family` | string | yes | Calibration grouping (ADR 0041). Generic example: `clinic.notes_completeness` |
| `answer_type` | string | yes | Module name |
| `declaration` | object | yes | The exact object hashed in §3.2. Question wording is policy (DEC-MOAT treats it as a private asset for a deployment), so this field is envelope-class but *deployment-private*: it is never exported to a public artefact. See §9 |
| `pin` | enum `required` \| `preferred` | yes | `required` for any family that can feed an admitted fact (ADR 0040: floating aliases are forbidden there). Default `required` |
| `must_record` | boolean | yes | ADR 0040 must-record vs best-effort. `true` for any family that can feed a fact; tooling families (ADR 0045) may be `false` |
| `data_class_ceiling` | enum | yes | The highest data class this question may be asked over (§5.4) |
| `cache_ttl` | ISO-8601 duration \| null | yes | Per family (ADR 0040). `null` means never reuse |
| `lineage` | object \| null | no | `parent_hash`, `proposer` (`person:<id>` \| `optimiser:<name>` \| `distillation:<name>`), `proposer_version`, `proposal_id` (ADR 0047). Non-identity |
| `activated_by` | actor ref | yes | The person who activated this version: the **author of record** (ADR 0039, 0047 point 3) |
| `activated_at` | timestamp | yes | |
| `retired_at` | timestamp \| null | no | Retiring never deletes observations |

---

## 4. Ids, hashes and canonical form

### 4.1 Record ids

- Every record in this RFC has a UUID primary key. UUIDv7 is recommended, for time ordering.
- **The observation id is generated by the caller before the instrument is called**, and passed into the create
  action (§6). An Oban retry or a crash between the call and the insert then cannot produce two rows for one call
  (iron law #07, idempotent jobs). The create is an upsert-or-conflict on `id`.
- References use the envelope's `evidence_ids` form (envelope §2.6), with new kinds: `observation:<uuid>`,
  `banding:<uuid>`, `admission:<uuid>`, `verdict:<uuid>`, `calibration:<uuid>`, `question:<uuid>`.

### 4.2 Digests

- Format: `"sha256:" <> lower hex`, over the canonical JSON (§4.3) of a defined subset. This is semantic-manifest §4.4
  and envelope §2.4, with one proposed difference.
- **Proposed: full length (64 hex characters, 256 bits) for every digest defined in this RFC**: `question_hash`,
  `wire_question_hash`, `wire_schema_hash`, `state_contract`, `input_hash`, `cache_key`, `record_hash` and the
  evaluation-set hashes. The manifest truncates to 128 bits for readability in a developer tool. These records are
  audit artefacts with a long life and an adversarial reader, and full digests cost nothing (envelope §4.2 asked
  exactly this). Digests this RFC *copies* from elsewhere keep their source's format unchanged: a model digest as the
  runtime reports it, and `ash_decisions` `content_hash` as stored. Q4 asks whether the envelope should adopt 256 bits
  too, so one implementation (`AshEnterprise.Provenance.Digest`) serves both.
- The digest of nothing is `null`, never the digest of `{}` (envelope §2.4 rule 4).
- Digest the normalised form (envelope §2.4 rule 1). For state, that is the exact JSON body sent on the wire: the state
  after projection and `Ash.Type.dump_to_embedded`, as `evaluate.ex` `default_state/1` builds it.

### 4.3 Canonical JSON

Semantic-manifest §7.2 applies verbatim (UTF-8, sorted keys, no whitespace, integers only, atoms as strings, explicit
`null`, arrays in order), with one rule made explicit for this RFC:

- **Probabilities, confidences, Score values and every other real number are decimal strings**, for example
  `"0.9412"`. §7.2 rule 4 forbids floats because float round-tripping is not portable. The string is the shortest
  decimal that round-trips the IEEE-754 double the runtime returned (Erlang `:erlang.float_to_binary(x, [:short])`).
  It is never rounded to a display precision. Postgres stores it as `numeric`. The band-table bridge hands it to FEEL
  as a `Decimal`, which is what FEEL does with floats anyway (ADR 0041).
- Distribution keys are the option values as strings (`"supports"`), or level indices as decimal strings (`"0"`,
  `"1"`) for `Score`, matching `Choice.probabilities` and `Score.probabilities`.

Q5 asks whether shortest-round-trip is the right rule, or whether a fixed precision should be declared per family.

### 4.4 Cache key

```
cache_key = digest(canonical_json({
  "input_hash":         <§5.4>,
  "model_digest":       <§5.3>,
  "runtime_version":    <§5.3>,
  "wire_question_hash": <§3.3>,
  "zone_id":            <§5.5>
}))
```

- This is seams §3.4 and ADR 0040 (`model digest ‖ question hash ‖ canonical state`), sharpened in three ways: the
  *wire* question hash instead of the declared one, the runtime version, and the zone.
- **Runtime version is in the key (proposed).** Law 6 makes the runtime version part of the verdict's identity, and
  a runtime release can change outputs (kernels, quantisation paths, a silent CPU fallback). The cost is that every
  runtime upgrade empties the cache. Q6.
- **Tenant is not in the key; tenancy is enforced by the lookup.** The ledger is a tenant-scoped platform resource, so
  a cache lookup is an ordinary tenant-scoped read and cannot see another tenant's rows. Putting the tenant in the key
  would be redundant. Leaving it out keeps one key per logical call.
- A cache hit **writes no observation**. The caller references the existing observation id. The key and TTL decide
  reuse. A hit on a row whose `answered_at + cache_ttl` has passed is a miss.

### 4.5 Record hash

Every record carries `record_hash`: the digest of its own canonical JSON, minus `record_hash` itself and minus every
payload-class field (§10). A record whose payload has been erased still verifies. `fact_snapshot_hash` in
ash_compliance covers the observation ids that produced its facts (ADR 0040); an export can carry `record_hash` so a
recipient can check each row.

---

## 5. The observation record

### 5.1 Shape

An observation is **the envelope core (envelope §2.1), unchanged, plus a `judgment` extension block**. One row per
question per call. A `Judgments` request that asks four questions writes four observations sharing one `request_id`.

```
Observation
├── id, record_version "0", record_hash
├── envelope        ── envelope §2.1 fields, unchanged (§5.2)
└── judgment
    ├── question    ── id, hash, version, family, wire_question_hash        (§5.2)
    ├── instrument  ── profile, rung, runtime, versions, digests, zone      (§5.3)
    ├── input       ── input_hash, state_ref, document/atoms, data class   (§5.4)
    ├── answer      ── kind, outcome, value, distribution, log-probs       (§5.5)
    ├── call        ── mode, request_id, cache_key, timing, usage          (§5.6)
    └── lineage     ── shadow_of, supersedes_nothing (observations never supersede)
```

### 5.2 Envelope core and question

The envelope fields keep their envelope meaning. How each is filled for an observation:

| Envelope field | For an observation |
|---|---|
| `semantic_id` | The evaluate action's `ash:` id (or a prompt action's, for the generative rung) |
| `definition_version` | That action's manifest content hash (envelope §2.3). It records which *shape* of the action ran |
| `tenant_id`, `actor_id`, `system_actor`, `impersonator_id` | The requesting actor, exactly as for any action (ADR 0039: evaluate actions run as the requesting actor) |
| `input_digest` | Equal to `judgment.input.input_hash`. Kept under both names so envelope consumers work unchanged |
| `output_digest` | Digest of the canonical `answer` block minus log-probs and raw reply |
| `redaction_digest`, `dropped_fields` | From the state projection, per envelope §2.4 rules 2 and 3 |
| `policy_decision_ids` | Envelope §2.5 rules. Populated for the evaluate action's authorization |
| `evidence_ids` | Candidate atoms are *not* here; they are in `judgment.input` (§5.4). `evidence_ids` names durable artefacts consulted, such as a prior observation the question was conditioned on |
| `correlation_id`, `process_instance_id`, `trace_id`, `span_id`, `depth` | Unchanged |

Actor and grant, added by this RFC:

| Field | Type | Req | Notes |
|---|---|---|---|
| `automation_principal` | string \| null | no | Set when the call was made by an automation principal (ADR 0043), for example `evidence_admitter`. Mutually exclusive with `system_actor` for the same row |
| `grant_ref` | object \| null | no | For an automation principal: `{grant_id, role, privilege, family, risk_tier}`. It records the grant row the principal's `ActorContext` held for this call. For a human actor: `null`; their authority is in `policy_decision_ids` |

Question block:

| Field | Type | Req | Notes |
|---|---|---|---|
| `question_id` | string (§3.1) | yes | |
| `question_hash` | digest (§3.2) | yes | |
| `question_version` | integer | yes | |
| `family` | string | yes | |
| `wire_question_hash` | digest (§3.3) | decision rung | |
| `question_set_hash` | digest | yes | Digest of the sorted list of `question_hash` values asked in the same request. This is law 6's "question-set hash" |

### 5.3 Instrument

| Field | Type | Req | Notes |
|---|---|---|---|
| `profile` | string | yes | The named profile the host resolved (ADR 0039: profile resolution is host code) |
| `rung` | enum `decision` \| `generative` \| `emulated` | yes | `emulated` = typed decisions derived from an in-zone generative runtime's log-probs. It is a separate calibration family, never pooled (ADR 0042) |
| `provider` | string | yes | The `req_llm` provider id, e.g. `typesafe` for an Ollaya-served decision model |
| `model_spec_requested` | string | yes | The model name as requested, without `base_url` or keys (§9) |
| `model_reported` | string \| null | yes | `AshAi.Actions.Result.model`: what the runtime said answered |
| `model_digest` | string \| null | yes | The content digest of the model weights as the runtime reports it. **Required non-null when the question's `pin` is `required`**, or the row may not feed admission (ADR 0040). How to obtain it is Q7 |
| `runtime` | string | yes | e.g. `ollaya`, `llama.cpp`, `ollama`, `vllm` |
| `runtime_version` | string | yes | Pinned version as reported by the runtime |
| `accelerator` | enum `gpu` \| `cpu` \| `unknown` | yes | What actually executed. Recorded because a runtime can fall back to CPU silently (HANDOFF §6). Observations with a different accelerator than the calibration run's are flagged at banding (Q8) |
| `wire_spec_version` | string \| null | no | The wire compatibility version the runtime declares (ADR 0042 contract tests) |
| `wire_schema_hash` | digest \| null | generative: yes | ADR 0046 point 6. The exact JSON Schema sent, after per-call narrowing |
| `sampling` | object \| null | generative: yes | Temperature, seed, top-p and similar, as sent. `null` for the decision rung |
| `zone_id` | string | yes | The zone the instrument runs in. Must equal `judgment.input.zone_id` or the call is a disclosure and never an instrument call (ADR 0042) |

`residency` (`in_cluster` \| `sub_processor`, seams §3.1) is **dropped as a stored field**. ADR 0042 makes it derived:
`in_cluster` means the instrument's zone equals the data's zone. Since no out-of-zone instrument exists (DEC-HOSTED),
every observation is `in_cluster` by construction.

### 5.4 Input

| Field | Type | Req | Notes |
|---|---|---|---|
| `input_hash` | digest | yes | §4.2: the exact state body sent |
| `state_ref` | object | yes | What the state was drawn from, as references: `{subject: {type, id}, document_version_hash?, atom_ids?, source_version?}` |
| `subject_type`, `subject_id` | string, string | yes | Denormalised from `state_ref` for queries |
| `rule_ref` | object \| null | no | For evidence work: `{bundle_hash, rule_id, predicate_id}` |
| `document_version_hash` | digest \| null | no | Required when the state came from a document |
| `candidate_atom_ids` | [string] | no | Atoms considered (ADR 0044 evidence contract) |
| `parser_version`, `atomiser_version` | string \| null | when a document | Law 6 |
| `retrieval` | object \| null | no | `{embedder_profile, embedder_digest, index_version}` when retrieval chose the atoms. Provenance only; not in the cache key. Q14 |
| `data_class` | enum `public` \| `synthetic` \| `internal` \| `customer_confidential` | yes | ADR 0042. Must be at or below both the zone ceiling and the question's `data_class_ceiling` |
| `residency_restriction` | string \| null | yes | The source data's residency tag: `null` for none, or the jurisdiction it is restricted to. A row with an unknown tag cannot exist, because untagged data never entered the zone |
| `zone_id` | string | yes | The data's zone |
| `jurisdiction` | string | yes | Denormalised from the zone record at write time, so every metric can split by it without a join (law 10; the org rule that a total must name its region) |
| `state` | JSON \| null | no | **Payload class** (§10). The state itself. Retained per zone and tenant policy; `null` after erasure or when the family retains digests only |

**The state is absent from the envelope class, always.** Only `input_hash` and `state_ref` are envelope-class. Whether
`state` is retained at all is per family (DEC-PRIVACY: state stays digest plus reference by default; encryption of
`state` is deferred in-zone, ADR 0040/0042 trigger table).

### 5.5 Answer

| Field | Type | Req | Notes |
|---|---|---|---|
| `outcome` | enum `answered` \| `cast_failed` \| `instrument_error` \| `timeout` \| `refused` | yes | A failure is still an observation (ADR 0046 point 3: a failed cast is recorded, never silently repaired). `refused` = the runtime declined, for example over-length state |
| `kind` | enum `noul` \| `choice` \| `score` \| `evidence` \| `extraction` | yes | `evidence` is the proposed four-way `Choice` (ADR 0039). `extraction` is the generative rung |
| `value` | JSON \| null | when answered | `Noul`: `null` (a noul has no collapsed value; see Q9). `Choice`/`evidence`: the option string. `Score`: the probability-weighted position as a decimal string. `extraction`: the cast value |
| `level` | string \| null | Score only | `Score.level` |
| `distribution` | object \| null | decision rung | Option (or level index) → decimal string. For `Noul`: `{"true": p, "false": 1 − p}`, derived from the single probability so every decision answer has the same shape. The runtime's own `probability` is kept verbatim in `raw` |
| `confidence` | decimal string \| null | Choice, Score, evidence | As returned. `Noul` has none. **`extraction` never has one** (ADR 0046 point 5) |
| `status` | enum `found` \| `not_found` \| `ambiguous` \| null | extraction only | ADR 0044 extract → verify |
| `source_ids` | [string] \| null | extraction, evidence | Atom ids only. For extraction, constrained on the wire to the packet's atom ids |
| `selected_atom_ids`, `limiting_atom_ids`, `missing_dimensions` | [string] | evidence, when available | ADR 0044 evidence contract. v0 decision models do not return these; they are filled by the evidence pipeline's own steps, and Q15 asks whether they belong on the observation or on a separate assertion record |
| `raw` | JSON \| null | no | **Payload class.** The runtime's raw answer for this question id (`provider_meta.raw_response` sliced to this question), or the generative raw reply before the Ash cast (ADR 0040, ADR 0046) |
| `logprobs` | object \| null | no | **Payload class.** Raw token log-probabilities where the runtime returns them (generative and emulated rungs only; the decision wire returns distributions, not token log-probs). `{source, format, top_k, tokens: [...]}`. Required for `emulated`, since its distribution is computed from them |
| `error` | object \| null | on failure | `{class, message_digest}`. The message itself is payload class, because runtime errors can echo input text |

**Disposition is not admission.** `evidence` values are `supports | contradicts | insufficient | not_applicable`, plus
the optional `wrong_scope` (SYNTHESIS §2.3). Nothing on the observation says `admitted`, `review`, `compliant` or any
other value from another layer.

### 5.6 Call

| Field | Type | Req | Notes |
|---|---|---|---|
| `mode` | enum `live` \| `shadow` \| `calibration` \| `eval` | yes | See §6.3. `replay` never writes, and a cache hit never writes, so neither appears |
| `request_id` | uuid | yes | Shared by every observation from one runtime request |
| `cache_key` | digest | yes | §4.4 |
| `shadow_of` | uuid \| null | shadow only | The incumbent observation this one shadows |
| `run_id` | uuid \| null | calibration/eval | The calibration or evaluation run (§8) |
| `requested_at` | timestamp | yes | When the call was sent. ISO-8601 UTC, microseconds |
| `answered_at` | timestamp \| null | yes | When the answer arrived (null on timeout) |
| `recorded_at` | timestamp | yes | Row insert time. Set by the database, not the caller |
| `latency_us` | integer \| null | yes | Wall time of the request. Shared across a `request_id` |
| `usage` | object \| null | no | As normalised by ReqLLM. Scope is the request, not the question |

### 5.7 Normative rules for observations

1. **Immutable.** No update action exists. Re-inference is a new row (law 2).
2. **No observation without a zone, a data class and a residency tag.** The create action rejects the row otherwise.
3. **A row whose `pin` is `required` and whose `model_digest` is null may be written** (the call happened and is a
   fact about the world) **but may never be banded into `admit`.** The banding action refuses it with a named error.
4. **Packets carry source ids, never quotations** (law 8). No envelope-class field holds document text.
5. **Floating aliases are invalid in `pin: required` families** (law 6). `model_spec_requested` naming an alias is
   allowed only if `model_digest` resolves it; the digest is what identity uses.

---

## 6. The replay contract

### 6.1 The rule

**The ledger's create action accepts every field of the observation as an input, including the answer. No change body
on that action calls an instrument, reads the clock for an identity field, or reads anything that is not an input.**

This is the AshEvents constraint (HANDOFF §6; seams §1.8; ADR 0040): during AshEvents replay, a change module's
`change/3` still runs and only its hooks are stripped. A create action that called the model in `change/3` would call
it again on replay and write a different answer into history.

Concretely:

- The instrument is called **before** the transaction: in the evaluate action's own `run`, in a `before_transaction`
  hook, or in an Oban worker. Its result, the caller-generated observation id, and `requested_at`/`answered_at` are
  passed to the create as arguments.
- Change bodies may compute **pure** derived fields from inputs only: digests (`input_hash` from `state`, `record_hash`,
  `cache_key`), the `Noul` distribution from its probability, and the denormalised `jurisdiction` from a zone record
  *passed in* (not looked up). Given the same inputs, they give the same output on replay.
- `recorded_at` is the one database-generated field. Replay restores it from the event rather than regenerating it
  (AshEvents `replay_non_input_attribute_changes`, or an explicit input). Q10 asks the implementer to confirm which.
- Banding, admission, verdict and calibration records follow the same rule: every create accepts its computed result
  as input. The band-table evaluation happens before the create; its `ash_decisions` evaluation id is passed in.

### 6.2 What replay means for each consumer

| Consumer | Reads | Never does |
|---|---|---|
| AshEvents replay of the ledger | Recorded create inputs | Calls an instrument or evaluates a band table |
| `ash_events_projections` rebuild | Observation, banding and admission events | Calls an instrument (ADR 0038: projectors never call models) |
| Compliance re-evaluation, audit pack | Admitted facts and their observation ids | Re-bands with a newer table unless explicitly asked; that would be a new banding record in `mode: shadow` |
| Cold-clone demo (DEC-REPLAY) | A recorded ledger fixture | Reaches a runtime. Output is labelled "replayed from recording <date> <model>" |

### 6.3 Modes at a call site

ADR 0040 declares three call-site modes. This RFC maps them onto records:

| Call-site mode | Instrument called? | Writes | Record `mode` |
|---|---|---|---|
| **cache** (default) | Only on a miss | On a miss, one observation | `live` |
| **replay** | Never. A miss is the error `replay_miss`, never a call | Nothing | — |
| **shadow** | The candidate instrument | One observation per question, with `shadow_of`. Never banded into anything but a shadow banding | `shadow` |
| calibration / eval run | Yes, over a labelled split | Observations tied to `run_id` | `calibration` or `eval` |

---

## 7. Banding, admission and human verdicts

### 7.1 Banding record

A banding says which band-table row an observation's answer fell into. It asserts nothing about the world and admits
nothing.

| Field | Type | Req | Notes |
|---|---|---|---|
| `id`, `record_hash`, envelope core | | yes | The actor is whoever ran the banding step |
| `observation_ids` | [uuid] | yes | Usually one. More than one when a band table reads several answers, e.g. an extraction plus its verification |
| `band_table` | object | yes | `{definition_key, definition_version, content_hash, definition_id, tenant_fork}`, copied from `ash_decisions` `Definition` at evaluation time. `tenant_fork` is the envelope §2.3 form (`"t3<-p5"`) |
| `decision_evaluation_id` | uuid | yes | The `ash_decisions` `Evaluation` row |
| `inputs` | object | yes | The flattened DMN inputs (probabilities as decimal strings, family, risk tier, jurisdiction). Envelope-class: these are derived numbers and codes, never text |
| `matched_rule_ids` | [string] | yes | From `Evaluation.matched_rule_ids`. **An empty list is a refusal, not a result**: a band table that cannot say which row fired is not auditable (ADR 0041). Needs the ash_decisions bump |
| `band` | enum `admit` \| `review` \| `omit` | yes | The band table's output (ADR 0041) |
| `fact_value` | JSON \| null | admit only | The fact value the table proposes |
| `mode` | enum `live` \| `shadow` | yes | |
| `flags` | [string] | no | e.g. `accelerator_mismatch`, `digest_missing`, `audit_sample_selected` |
| `banded_at` | timestamp | yes | |

### 7.2 Admission record

The admission is the action that turns a banding into a fact, a review task, or nothing. It is performed by a person
or by an automation principal holding a grant (ADR 0043).

| Field | Type | Req | Notes |
|---|---|---|---|
| `id`, `record_hash`, envelope core | | yes | |
| `banding_id` | uuid | yes | |
| `observation_ids` | [uuid] | yes | Denormalised |
| `result` | enum `admitted` \| `review` \| `omitted` | yes | `omitted`, not `unknown`: decided by Luke on 2026-09-28 (Q11) |
| `actor_kind` | enum `person` \| `automation_principal` | yes | Never a system actor with bypass; never the `ai` system actor (ADR 0043) |
| `grant_ref` | object | automation: yes | `{grant_id, role, privilege, family, risk_tier, tenant_id}` from the principal's `ActorContext`. The grant must name a question version whose calibration satisfies the optimise-split rule (ADR 0043) |
| `fact_ref` | object \| null | admitted | `{fact_id, subject, predicate, value}` of the fact written through the ordinary action |
| `review_task_ref` | object \| null | review | The human task opened (BPMN user task or equivalent) |
| `audit_sample` | boolean | yes | `true` when this admission was routed to review by the random audit sample (ADR 0041), even though the band said `admit` |
| `supersedes` | uuid \| null | no | A prior admission this replaces. Admitted facts are superseded, never edited (ADR 0044) |
| `effective_at` | timestamp | yes | |

Normative:

1. An automation principal with no matching grant row admits nothing (ADR 0043).
2. **Human entries win.** An automatic admission never overwrites or lowers a fact a person entered. It may only fill
   an absence.
3. `contradicts` never auto-admits a failing fact. It routes to review at any probability (DEC-AUTONOMY).
4. `omitted` writes no fact, so a predicate declared `missing: :unknown` evaluates to `unknown` in ash_rules.
   Uncertainty never collapses to compliant.

### 7.3 Human verdict record

| Field | Type | Req | Notes |
|---|---|---|---|
| `id`, `record_hash`, envelope core | | yes | The actor is the reviewer |
| `observation_id` | uuid | yes | |
| `question_hash`, `model_digest`, `input_hash`, `state_ref` | | yes | Denormalised from the observation (seams §1.8: override events carry the question, state reference, model answer and version) |
| `model_answer` | object | yes | The observation's `kind`, `value` and `distribution` |
| `human_answer` | JSON | yes | In the question's own answer space (an option, a level, `true`/`false`, or an extracted value) |
| `basis` | enum `review_task` \| `audit_sample` \| `labelling` \| `override` | yes | Keeps the sample's selection visible (ADR 0047 point 8: reviewed data is biased) |
| `labelling_protocol` | string \| null | labelling | Protocol version |
| `double_label_of` | uuid \| null | no | For inter-rater agreement |
| `split` | enum `optimise` \| `calibration` \| `test` \| `audit` \| null | labelling | Assigned by source document, disjoint (ADR 0041) |
| `note` | string \| null | no | **Payload class.** Free text from a reviewer can quote a document |

---

### 7.4 The fact, as sets read it (ADR 0048)

ADR 0048 (accepted 2026-10-02) makes admitted facts the vocabulary of filters, search, segments and standing queries, not only of
rules. A set reads facts in bulk, in SQL, with no model in the path. That puts requirements on the admitted fact that a
single-subject rule never needed. They are recorded here so that v0 freezes with them rather than being migrated to
them.

Every fact written by an admission (§7.2 `fact_ref`), and every fact a person enters directly, carries:

| Field | Type | Req | Notes |
|---|---|---|---|
| `subject_type`, `subject_id` | string, id | yes | Any Ash resource, not only a passage or document. Indexed together with `predicate` |
| `predicate` | string | yes | The question id (§3.1) for a judged predicate, or the fact-schema name for a crisp one; one namespace |
| `value` | JSON | yes | In the predicate's declared type. For a judged boolean-shaped predicate, `true` is *in* and `false` is *out* |
| `scope` | object \| null | yes | `null` for a fact about the subject alone. Otherwise the context it holds in (for example `{tenant_id, requirement_set_id}`). A filter always runs in the actor's scope |
| `subject_state_digest` | digest \| null | judged: yes | The digest of the state projection the question saw (`state_ref`, §5.4). When the subject's current projection digest differs, the fact is **stale** |
| `valid_until` | timestamp \| null | no | Declared per predicate. An expired fact is `unknown` |
| `admission_grade` | enum `person` \| `grant` | yes | Who admitted it (§7.2 `actor_kind`). Consumers state the minimum grade they accept (Q19) |
| `admission_id` | uuid \| null | judged: yes | Back-reference for provenance on every search hit |
| `superseded_by` | uuid \| null | yes | Facts are superseded, never edited (ADR 0044). "Current" means not superseded |

Normative:

1. **Membership is derived, never stored.** For a judged predicate, a subject is *in* when a current, fresh, unexpired
   fact in the actor's scope has the declared "holds" value, and *out* when it has the "does not hold" value. It is
   *unknown* otherwise: no fact, an `omitted` admission, a `review` task open, stale, or expired. No record stores a
   boolean that could lose the third value.
2. **Freshness is checkable in SQL.** The host keeps each subject's current projection digest per question, updated
   in the same transaction as the subject's change, so staleness is a join, not a model call. The change also enqueues
   reassessment (a materialisation trigger).
3. **The set evaluator reads this table only.** It never reads observations for membership. Observations may be read
   only for labelled ordering (ADR 0048, "scores order; facts decide").
4. **Indexes.** At least `(predicate, scope, subject_type, subject_id)` and a partial index on current facts. The set
   evaluator's plans are part of its acceptance test.
5. **Exploratory observations** (ADR 0048: undeclared questions run over a bounded candidate set) are ordinary
   observations with `question.exploratory = true` and no family. They are never banded, never admitted, never used
   for calibration unless a person labels them, and they carry the shortest retention class (§10).

## 8. Calibration runs and the band-table link

### 8.1 Calibration run record

One record per `(family, question_hash, model_digest, runtime_version, evaluation-set hash, zone)` (ADR 0041, sharpened
with the runtime version and zone).

| Field | Type | Req | Notes |
|---|---|---|---|
| `id`, `record_hash`, envelope core | | yes | |
| `family` | string | yes | |
| `question_hashes` | [digest] | yes | Usually one. More than one only for a multi-question band table |
| `question_lineage` | object | yes | Copied from the question record, including `proposal_id` and the `optimise_split_hash` a machine proposer saw (ADR 0041, 0047) |
| `instrument` | object | yes | The §5.3 fields that identify it: profile, rung, model digest, runtime and version, accelerator, wire-schema hash if generative |
| `zone_id`, `jurisdiction` | string | yes | A run in one jurisdiction does not license a band table in another (ADR 0042) |
| `eval_set` | object | yes | `{eval_set_id, eval_set_hash, split_hashes: {optimise, calibration, test, audit}, label_set_hash, labelling_protocol}` |
| `n` | object | yes | Total, and per class, on the calibration split. The verifier compares it with the family's minimum n (pending) |
| `metrics` | object | yes | Reliability bins, expected calibration error, Brier score, per-class precision and recall at each candidate threshold, selective accuracy and coverage (ADR 0041). All numbers as decimal strings |
| `observations_digest` | digest | yes | Digest of the sorted observation ids the run produced (`mode: calibration`), so the run can be re-scored from the ledger without re-inference |
| `result` | enum `proposed_table` \| `no_table` \| `regression` | yes | Negative results are kept (ADR 0047 point 7) |
| `proposed_band_table` | object \| null | no | `{definition_key, definition_version}` of the *draft* table the run produced |
| `pass_bar` | object | yes | The pre-registered pass bar and kill criteria (ADR 0047 point 7) |
| `started_at`, `finished_at` | timestamp | yes | |

The run's labelled items and their text are **not** in the record. They live in the zone's evaluation store and never
in git, Plane or a public artefact (DEC-MOAT; SYNTHESIS §8).

### 8.2 The band-table link

A band table is an `ash_decisions` `Definition` (DMN). That resource is upstream and generic, so this RFC does not add
fields to it. The link is a separate host-side record:

**Band-table certification** (one per band-table definition content hash per calibration run):

| Field | Type | Req | Notes |
|---|---|---|---|
| `id`, `record_hash`, envelope core | | yes | |
| `definition_id`, `definition_key`, `definition_version`, `content_hash` | | yes | The published definition |
| `family` | string | yes | |
| `calibration_run_id` | uuid | yes | |
| `model_digest`, `runtime_version` | string | yes | Must equal the run's. The verifier refuses a table naming a digest with no run (ADR 0041) |
| `optimise_split_disjoint` | boolean | yes | The verifier's check that no calibration item intersects the optimise split used to produce the question version |
| `verifier_version` | string | yes | |
| `verified_at` | timestamp | yes | |

**Activation** is not a field here. It is the existing validate → approve → activate lifecycle, and its record names
the activating person, who is the **author of record** for the band table (ADR 0041; operator answer Q10). A banding
record points at `(definition_key, definition_version, content_hash)`. From there the chain is: certification →
calibration run → evaluation set hash, and activation → approver → effective date. That is ADR 0041's "why was this
fact admitted?" answer as joins.

---

## 9. What must NOT be in any record

1. **Document text in any envelope-class field.** Packets carry atom ids; text is resolved from the document store at
   display time (law 8).
2. **Endpoints and credentials.** No `base_url`, host name, IP address or API key. A profile is recorded by name and
   zone. Where a runtime answered is an operational fact about the zone, kept with the zone record, not on every row.
3. **Model output presented as a reason.** A System One model gives no reasons. Generated prose, if kept at all, is a
   payload-class field labelled commentary, and is never an explanation (law 8).
4. **Probabilities in a fact.** Facts are crisp. The observation keeps the probability; the fact references the
   observation.
5. **A floating alias as identity** in a `pin: required` family.
6. **Deployment question wording in a public artefact.** The `declaration` field of a question record is
   envelope-class for retention (it holds no personal data) but deployment-private for publication (DEC-MOAT). Public
   fixtures use synthetic wording only.
7. **Customer content in fixtures, tests, transcripts, Plane or commits.** Fixtures are synthetic and CC0.
8. **US-only restricted data, or any data whose residency tag the zone cannot satisfy.** It never entered the zone, so
   it cannot be in a row (ADR 0042 admission rule).

---

## 10. Stores and retention (answering docs-s1 C10)

**Decision proposed: the judgment ledger is its own set of tables, not the domain event log.**

- Observations are high volume: one per question per call, with calibration and shadow runs multiplying that.
  Consequential domain events should not carry them (docs-s1 C10, the D3 position).
- Each ledger record is written by a **create action on a host resource built on `AshEnterprise.Platform.Resource`**
  (ADR 0040), so AshEvents audits it, and tenancy, correlation and policies are inherited. Opting a high-volume
  family out of AshEvents audit is explicit and local (`audit: false` on that resource or action), and **never
  permitted for a family that can feed a fact**, because the admission's provenance would then be unaudited.
- **Domain events carry summaries and ids only.** For example an `EvidenceAdmitted` event carries the admission id,
  the fact ref and the observation ids. It never copies probabilities or state.

Retention classes, extending envelope §2.7:

| Class | Fields | Retention | Erasure |
|---|---|---|---|
| **Envelope** | Everything not listed below: ids, digests, versions, codes, decimal-string probabilities, timestamps, refs | Indefinite | Nothing personal to erase by construction |
| **Payload** | `input.state`, `answer.raw`, `answer.logprobs`, `answer.error` message, `human_verdict.note` | Per zone and tenant policy; per family (`digest_only` families never store it) | Erasable. Erasure sets the field to `null` and writes a tombstone record `{record_id, field, erased_at, basis}`. `record_hash` still verifies, because payload fields are outside it (§4.5) |
| **Evidence blob** | Documents, atoms' text, exports | Compliance programme | Erasable. Erasing a document leaves `document_version_hash` and atom ids valid as references to something that no longer resolves |

**Erasure versus replay (SYNTHESIS §7 Q7, ADR 0024).** Replay reads the answer, not the state, so it survives erasure.
What erasure costs is shadow evaluation and re-calibration over the erased subject, which is the correct loss. Payload
encryption stays deferred inside one zone with full-disk encryption and one operator; the column exists from the first
migration so turning it on is a data change (ADR 0040, ADR 0042 trigger table).

---

## 11. Versioning and compatibility (normative)

- Every record carries `record_version`, a major version only: `"0"`. This follows semantic-manifest §6.1.
- **Additive within a major version**, as semantic-manifest §6.2: a new optional field, a new value on an open enum
  (`outcome`, `flags`, `basis`, `runtime`), or populating a field that was always `null`.
- **Closed enums** (changing them is breaking): `kind`, `mode`, `band`, `result`, `data_class`, `rung`, and the
  disposition values.
- **Breaking, requiring `"1"`**: removing or renaming a field; changing a field's JSON type; changing the
  `question_hash`, `wire_question_hash`, `cache_key` or `record_hash` input subsets; changing the digest algorithm or
  length; changing the canonical-JSON rules or the decimal-string rule; moving a field between the envelope and
  payload classes.
- Consumers ignore unknown fields and treat unknown values of open enums as opaque.

---

## 12. Examples (synthetic clinic)

Digests below are shortened placeholders (`sha256:9f2c…`), not real hashes. The frozen version ships real fixtures
(§14).

**A Noul, live.** "Do the appointment notes document a follow-up plan?" asked of a decision model over a projection
of one appointment's notes.

```json
{
  "id": "0192a3b4-…",
  "record_version": "0",
  "envelope": {
    "semantic_id": "ash:v0:ClinicDemo.Scheduling.Appointment#actions/judge_notes",
    "definition_version": "sha256:4c1d…",
    "tenant_id": "…", "actor_id": "…", "system_actor": null,
    "input_digest": "sha256:77ab…", "output_digest": "sha256:e012…",
    "correlation_id": "…", "trace_id": "…", "span_id": "…", "depth": 1
  },
  "judgment": {
    "question": {
      "question_id": "judgment:v0:ClinicDemo.Scheduling.Appointment#judgments/notes_document_follow_up",
      "question_hash": "sha256:9f2c…", "question_version": 1,
      "family": "clinic.notes_completeness",
      "wire_question_hash": "sha256:9f2c…", "question_set_hash": "sha256:b810…"
    },
    "instrument": {
      "profile": "decision_default", "rung": "decision", "provider": "typesafe",
      "model_spec_requested": "laya", "model_reported": "laya:typed-decisions",
      "model_digest": "sha256:… (as the runtime reports it)",
      "runtime": "ollaya", "runtime_version": "x.y.z", "accelerator": "gpu",
      "wire_schema_hash": null, "sampling": null, "zone_id": "zone.lab"
    },
    "input": {
      "input_hash": "sha256:77ab…",
      "state_ref": {"subject": {"type": "appointment", "id": "…"}},
      "subject_type": "appointment", "subject_id": "…",
      "data_class": "synthetic", "residency_restriction": null,
      "zone_id": "zone.lab", "jurisdiction": "EX-1", "state": {"notes": "…synthetic…"}
    },
    "answer": {
      "outcome": "answered", "kind": "noul", "value": null,
      "distribution": {"false": "0.0588", "true": "0.9412"}, "confidence": null,
      "raw": {"type": "boolean", "probability": 0.9412}
    },
    "call": {
      "mode": "live", "request_id": "…", "cache_key": "sha256:31fe…",
      "requested_at": "2026-10-02T14:03:11.204118Z", "answered_at": "2026-10-02T14:03:11.211502Z",
      "recorded_at": "2026-10-02T14:03:11.219330Z", "latency_us": 7384,
      "usage": {"input_tokens": 212}
    }
  },
  "record_hash": "sha256:0d4e…"
}
```

**A Choice feeding triage.** "Which urgency does the chief complaint describe?" with `of: ClinicDemo.Urgency`
(`routine | soon | urgent`). The observation has `kind: "choice"`, `value: "soon"`, a three-way `distribution` and
a `confidence`. A banding record then evaluates the triage DMN with `inputs` holding the three probabilities as
decimal strings, gets `band: "review"` and `matched_rule_ids: ["DecisionRule_4"]`. The admission record has
`result: "review"` and a `review_task_ref`. A human verdict follows with `human_answer: "urgent"`,
`basis: "review_task"`.

**An extraction, then its verification.** A generative proposal of a licence expiry date from a synthetic clinician
credential: `rung: "generative"`, `kind: "extraction"`, `status: "found"`, `source_ids: ["atom:12"]`,
`wire_schema_hash` set, `confidence` absent. A second observation asks a `Noul`, "Does atom 12 state that the expiry
date is 2027-03-31?". The banding record lists both observation ids.

**A replay hit.** In replay mode no record is written. The caller receives the existing observation id.

**An erased state.** `input.state: null`, `answer.raw: null`, a tombstone record naming both fields, and an
unchanged `record_hash`.

---

## 13. Open questions (all of them)

Numbered for reference in review. Each has a proposed position or an explicit deferral. Settled so far: Q11
(`omitted`, 2026-09-28). Q7 stays open until S1-21 reports.

**From this RFC**

- **Q1. Is the state projection part of `question_hash`?** (ticket open question 1.) *Proposed:* yes, as the digest of
  the projection's declared output shape (`state_contract`), not its module name. Residual hazard: a content change
  with an unchanged shape keeps the hash. Alternative: hash the projection's manifest content hash, which churns on any
  code edit.
- **Q2. Should `judgment:` join `dmn:` and `bpmn:` as schemes proposed back to the semantic-manifest RFC?** (ticket open
  question 2; envelope §4.5.) *Proposed:* yes, all three together, in one proposal to that RFC's reviewers.
- **Q3. Is `family` outside the hash?** *Proposed:* yes; family moves are recorded on the question record.
- **Q4. Digest length.** (ticket open question 3; envelope §4.2; Lane G "digest truncation".) *Proposed:* 256 bits for
  every digest this RFC defines, and the envelope adopts 256 too so one implementation serves both. The manifest keeps
  128 for developer ergonomics.
- **Q5. Decimal-string precision.** *Proposed:* shortest round-trip of the returned double. Alternative: a declared
  precision per family.
- **Q6. Runtime version in the cache key?** *Proposed:* yes, accepting cache loss on every runtime upgrade while the
  runtime ships this often.
- **Q7. Where does `model_digest` come from?** **Answered 2026-10-02 by S1-21's live run: yes, over HTTP.**
  Ollaya's `/api/tags` (all installed models) and `/api/ps` (currently loaded, with device and `size_vram`)
  both report a sha256 digest per model; the decide reply itself carries only the model name. The profile
  resolver therefore takes the digest **at call time** from the loaded model's `/api/ps` entry, falling back
  to `/api/tags`, exactly as the spike's `environment.txt` capture does (laya
  `6d17e5fb…9b25ccb07867f9f146a791673ba`, winnow `dd4bf88a…e22b9793f82d226`; hosts on Ollaya 0.7.5 and
  0.9.0 respectively — which also settles Q6's premise that the runtime version must be part of the cache
  key, since it varies across a single routed fleet). Two corollaries recorded: `/api/ps`'s device field
  feeds Q8's accelerator flagging for free; and a runtime that stops exposing a digest disables
  `pin: required` families for admission until it does again (fail closed, as this section already
  proposed).
- **Q8. Accelerator mismatch.** Should an observation computed on CPU when its calibration ran on GPU be refused at
  banding, or only flagged? *Proposed:* flagged, and refused for `admit` bands.
- **Q9. Noul `value`.** A noul deliberately has no collapsed value (`noul.ex` moduledoc). *Proposed:* `value: null`
  and a two-way `distribution`, so every decision answer has one shape.
- **Q10. `recorded_at` on replay.** Restored from the event via `replay_non_input_attribute_changes`, or made an
  explicit input? For the implementer to confirm against AshEvents.
- **Q11. The admission value `omitted` vs `unknown`.** **Settled: `omitted`, decided by Luke on 2026-09-28.** ADR 0038
  says `admitted | review | omitted`; `unknown` is an ash_rules outcome, and reusing the word across layers is the
  mixing ADR 0038 forbids. SYNTHESIS §2.3 is amended to match.
- **Q12. Cache-hit usage records.** A cache hit writes nothing (§4.4). Should high-consequence families record a
  lightweight "used" event so audit sees each use? *Proposed:* no; the admission or fact that consumed the observation
  already references it.
- **Q13. Must-record failure semantics.** If the ledger insert fails after a successful call in a must-record family,
  the answer is discarded and the call site returns an error (fail closed). *Proposed:* yes; confirm.
- **Q14. Retrieval provenance.** Are embedder digest and index version part of the verdict's identity (law 6 does not
  list them)? *Proposed:* provenance only in v0, not identity and not in the cache key. Retrieval quality is measured by
  the audit sweep (ADR 0044). Revisit when `ash_evidence` lands.
- **Q15. Evidence assertion: the observation or its own record?** ADR 0044's evidence contract (selected and limiting
  atoms, missing dimensions) mixes instrument output with pipeline steps. *Proposed:* a separate `ash_evidence`
  assertion record that references observations, defined in that package's own RFC. The v0 observation carries the
  optional fields so a single-step pipeline need not create both.
- **Q16. Question-record materialisation.** Is the question record written at activation, or lazily at first use?
  *Proposed:* at activation, because activation names the author of record.
- **Q17. Profile record.** Should instrument profiles also be materialised as append-only records (so the observation
  references a profile version instead of repeating its fields)? *Proposed:* not in v0; repeat the fields. Volume is
  small next to state.
- **Q18. Jurisdiction codes.** ISO 3166-2 subdivision codes *proposed*; the zone record owns the code. (Examples here use the placeholder `EX-1`, because public doctrine names no places.)

- **Q19. Does admission grade vary by consumer?** (ADR 0048; SYNTHESIS §7 Q13.) *Proposed:* one fact per predicate and
  scope, carrying `admission_grade`; each consumer states the minimum grade it accepts (for example, a search filter
  accepts `grant`, a high-severity rule requires `person`). Not a band table per consumer.
- **Q20. Staleness granularity.** A fact goes stale when the digest of the question's *state projection* changes, not
  when any field of the subject changes. *Proposed:* yes. This is the reason Q1 puts the projection in the question's
  identity.
- **Q21. Where facts live.** One host facts table keyed by subject, predicate and scope (generic, one index strategy),
  or columns on each subject resource (faster, but a migration per question)? *Proposed:* one host table, with derived
  Ash calculations doing an `exists` over it; per-resource columns only as a measured optimisation.
- **Q22. Standing-query events.** A membership change found by the Rete evaluator is an event (`entered` / `left` /
  `became_unknown`). Is it a judgment record? *Proposed:* no. It is an ordinary platform event on the standing query's
  resource, referencing the fact and admission ids, so it inherits audit and retention without a new record type.

**The provenance envelope's own open questions (envelope §4.1–§4.6)**

- **E1 (§4.1) Its own table?** *Proposed for judgments:* yes, the ledger is its own table (§10). For the general
  envelope over actions, processes and decisions: **deferred** to AST-9. This RFC does not need the answer, because
  every judgment record embeds the envelope core in its own row.
- **E2 (§4.2) Truncation.** See Q4.
- **E3 (§4.3) `policy_decision_ids` for reads.** **Deferred** to AST-9. Judgment records are all writes, so the
  envelope's write-path capture covers them.
- **E4 (§4.4) Composition `semantic_id`.** *Proposed for judgments:* one observation per question with a shared
  `request_id`, and the action's own `semantic_id`. That is the parent-link answer, applied where it is cheap. The
  general composition case is **deferred** to AST-9.
- **E5 (§4.5) `dmn:`/`bpmn:` schemes.** See Q2.
- **E6 (§4.6) Retention enforcement.** Classes defined in §10. The mechanism (time partitioning, tombstone job) is
  **deferred** to CORE-LEDGER, with partitioning of the ledger tables by `recorded_at` proposed from the first
  migration.

**The six Lane G questions (wip-ast §2, AST-9)**

- **G1. Occupancy scope of "safe"** (BPMN migration and restart). Not a judgment-record concern. **Deferred** to AST-9.
- **G2. Does `needs_restart` outrank `unknown`?** Not a judgment-record concern (a BPMN migration classifier question).
  **Deferred** to AST-9.
- **G3. Restart semantics.** Relevant only in that a restarted process must not re-ask a question it already has an
  observation for. *Proposed:* the process reads the ledger by `cache_key` in cache mode, so restart is replay-safe by
  §6. Otherwise **deferred** to AST-9.
- **G4. The FEEL engine axis.** Relevant only in that band tables must evaluate identically on either engine. The
  banding record copies `content_hash` and `matched_rule_ids`, so an engine change shows as a change in matched rows
  under shadow. *Proposed:* record the engine and its version in the banding record's `band_table` object (additive).
  The engine choice itself is **deferred** to AST-9.
- **G5. Digest truncation.** See Q4.
- **G6. Per-element BPMN semantic ids.** Not needed here. **Deferred** to AST-9 and the `bpmn:` scheme proposal (Q2).

---

## 14. Exit criteria for freezing v0

From S1-24's acceptance sketch, applied to this draft:

| AC | Kind | State of this draft |
|---|---|---|
| AC-1: fixtures validate against a draft-2020-12 schema in CI | static | **Not done.** The schema and fixtures are written when the RFC moves to ash_enterprise `docs/rfc/` (§15). The fixture list is §12 plus: Choice with abstention, evidence answer with atom ids, banded admitted, banded review then overridden, shadow diff |
| AC-2: re-serialising a fixture gives byte-identical `question_hash` and `cache_key` | static | **Not done** (golden test with AC-1) |
| AC-3: every seams §3.3 field plus region, mode, model digest and runtime version is in the schema or dropped with a reason | manual | **Done in prose**, §16 |
| AC-4: envelope §4.1–4.6 and the six Lane G questions each answered or deferred | manual | **Done**, §13 |
| AC-5: no fixture contains document free text | static | Rule stated (§9); the sentinel grep test lands with the fixtures |
| AC-6: Luke marks it "Accepted — v0 frozen" | manual | **Closed 2026-10-02** — "Accepted - v0 frozen" (14:37 UTC) + "YES - fold S1-58" (14:39 UTC); fold present as §7.4; Q7 answered via S1-21 live run. |

Dependencies: S1-21 (spike-0: the real `Result.model`, digest availability and error shapes); S1-37 and S1-39 as
listed on the ticket; the ash_decisions dependency bump for `matched_rule_ids`.

---

## 15. Moving it to its public home

When frozen, per the ticket:

1. Copy this text to `ash_enterprise/docs/rfc/judgment-record-v0.md`. The text is generic (checked for this draft: no
   deployment names, question wording, thresholds, customer data or host names).
2. Write `judgment-record-v0.schema.json` and the fixtures under `docs/rfc/fixtures/judgment/`, synthetic and
   REUSE-annotated CC0, with a validator test.
3. Update `docs/verification/provenance-envelope.md` to "Superseded in part by judgment-record-v0 §3–§5", with the
   answers from §13 E1–E6.
4. Write the one-page review pack for Luke: decisions made, questions deferred, and the §16 diff.

---

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

---

## 17. Changelog

- **Revision 1 (2026-09-28).** First draft, written in the private programme repo during the overnight run. Proposed,
  not frozen.
- **Revision 4 (2026-10-02).** Q7 answered from S1-21's live run: digests come over HTTP from `/api/tags` and
  `/api/ps` at call time (the decide reply carries the name only); corollaries recorded for Q6 (runtime version
  varies across a routed fleet — belongs in the cache key) and Q8 (`/api/ps`'s device field feeds accelerator
  flagging). AC-6's S1-21 dependency cleared; the freeze now awaits Luke's read and the S1-58 fold-in call
  (S1-57's §6 feed-in is ready). Evidence: clinic-demo `results/live-2026-10-02/environment.txt`.
