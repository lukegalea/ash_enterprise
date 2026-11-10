# RFC: The judgment record, v2 (DRAFT — NOT FROZEN)

| | |
|---|---|
| **Status** | **v2 — FROZEN. Luke's review approved 2026-10-08** — his review covered the five flagged judgment calls of Appendix B, all approved. **Supersedes nothing:** v1 remains the frozen contract of record for v1 implementations (v1 frozen at sha256 69f0f333…d03a); v2 governs the temporal field table (§7.4). Drafted per S1-68 under the AST-146 temporal-swap design note (Luke green-light 2026-10-07: "wait for AST-146 and then proceed with maximum parallel"). Public landing per §15. |
| **Revision** | **v2 (2026-10-07, frozen 2026-10-08; supersedes nothing — see Status).** The surgical temporal edit per the design note (§3: "this is a v2, plainly"): §7.4's field table loses `superseded_by` and gains `valid_at` (the record-validity period) and `scope_hash`; §7.4's implementation notes are rewritten to the temporal mechanism; every §7.4 normative and the §7.2 rules are carried verbatim. The §11-based breaking-change declaration and the change→justification audit live in Appendix B; no other section changes. History: v1 (2026-10-02, superseding v0 sha256 70eb8192…f160) applied the staged errata consolidation (`rfc/S1-24-v1-errata-consolidation.md`, A1–A13) in place — ten adopt-items verbatim, three forks (A4/A7/A9) at their recommended defaults; that amendment map and no-change audit remain in Appendix A. |
| **Work item** | Plane S1-68 (this v2 draft), under S1-24 (F-RFC-JUDGMENT), parent S1-4 (T-CORE). Linked: AST-146 (the gating design note), AST-147/AST-148 (the implementation and equivalence battery this draft specifies), AST-9 (Lane G provenance envelope) |
| **Gate** | v1's freeze is closed (2026-10-05). **v2's freeze is closed 2026-10-08** — Luke's review approved the five flagged judgment calls (Appendix B); v2 governs the temporal field table |
| **Target** | `ash_judgments` (ledger, facts, registry, calibration fragments), the host ledger/banding/facts resources in ash_enterprise, `ash_evidence` (packets, to come), `ash_decisions` (band tables, read-only here) |
| **Extends** | The provenance envelope (`ash_enterprise/docs/verification/provenance-envelope.md` §2.1). Reuses the semantic-manifest RFC's id grammar (§4.3), hash format (§4.4) and canonical JSON (§7.2) |
| **Grounded against** | The landed substrate, 2026-10-02: `ash_judgments` at `ca9b6cb` (registry AST-87; ledger AST-88 `3959aba`; cache/replay/shadow AST-89 `f6e8d6c`; telemetry AST-90 `6166183`; calibration AST-91 `ca9b6cb`; bridges AST-92/93/94/95 at `e3639a3`/`7edd3bf`/`25359f0`/`e67a6c4`; extraction type `9b36394`); `ash_rules` `ede91fd` (set evaluator) + `2e25647` (standings); host wiring `9fad00e` + banding pipeline `d582f88`; the public v0 landing `81116c6`/`3075a14`; `ash_ai` 1.1.0 and `req_llm` 1.24.0 as locked; `ash_decisions` pinned `040ce6d` (matched-rule recording `787fa47` in the pin; bump `f1f5545`); ADRs 0038–0048 (all accepted); CLIN-34's live extract→verify run |
| **Where this draft lives** | The private programme repo, `rfc/S1-24-judgment-record-v2-DRAFT.md`, beside the frozen v1. On freeze it moves to public `ash_enterprise/docs/rfc/judgment-record-v2.md`; v1's public copy, schema and fixtures stay byte-untouched |
| **Supersedes** | **Nothing.** Per Luke's freeze ruling (2026-10-08): v1 remains the frozen contract of record for v1 implementations; v2 governs the temporal field table (§7.4) alongside it |

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
to one deployment. Where a record shape now exists as landed code, this revision names it the **contract-of-record**:
the prose stays normative, the fragment is the executable half, exactly as `schema.json` is for §3–§5.

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

### 1.2 Non-goals for v1

- Implementation. Implementation has *happened* (§2); what this RFC still does not specify is deployment detail.
- The registry DSL grammar. ADR 0039 fixes its properties; the package (`AshJudgments.Registry`) settles its syntax.
  This RFC fixes only the registry *key* and the fields a question record must expose (§3).
- Threshold values, minimum n per family, and which families get an automatic band. Those are ADR 0041 pending items
  and deployment data.
- Any deployment's predicates, question wording, band tables or labelled data.
- Retrieval scoring records (BM25 and vector scores, reranker scores) beyond the ids and versions that identify what
  was considered. Those belong to `ash_evidence`; Q14 is settled — the §5.4 block is provenance only (§5.4).
- A wire format for exchanging records between installations. v0 is a storage and export contract; so is v1.

---

## 2. What exists today (verified 2026-10-02 against the landed set)

| Piece | Where | What it gives this RFC | What it does not give |
|---|---|---|---|
| `AshAi.Actions.Evaluate` | `deps/ash_ai/lib/ash_ai/actions/evaluate.ex` | The call. State = the action's arguments (`default_state/1`) or a `state:` override. Questions come from the return type or a runtime `questions:` option. Answers are cast with `Ash.Type.cast_input` + `apply_constraints` | Any record. A generic action is never audited by AshEvents |
| Answer types | `deps/ash_ai/lib/ash_ai/evaluate/{noul,choice,score,judgments}.ex`; `AshJudgments.Evaluate.Extraction` (`9b36394`) | `Noul{probability}`; `Choice{value, probabilities, confidence}`; `Score{value, level, probabilities, confidence}`; `Judgments` = many questions in one request; `Extraction{status, value, source_ids}` — no confidence, structurally | Token log-probs. No `Evidence` type yet upstream (proposed, UP-AI-EVIDENCE-TYPE) |
| `AshAi.Actions.Result` | `deps/ash_ai/lib/ash_ai/actions/result.ex` | `model` (the runtime's reported id), `usage`, `provider_meta` | A digest. `model` is a name string |
| `req_llm` `typesafe` provider | `deps/req_llm/lib/req_llm/providers/typesafe.ex` | `POST /v1/systemone`; per-call `base_url`; `provider_meta.raw_response`; `noul` normalised to `probability` | A `TYPESAFE_BASE_URL` env read; any digest field; log-probs |
| `AshAi.Actions.Prompt` | `deps/ash_ai/lib/ash_ai/actions/prompt.ex` | The generative rung, decoded under a schema derived from the Ash return type, re-cast after | Per-call schema narrowing upstream; string-keyed refinement-complete schema (typed-output §1.4) |
| Provenance envelope | `docs/verification/provenance-envelope.md` (superseded in part by judgment-record-v0 §3–§5) | The core struct: `semantic_id`, `definition_version`, actor fields, `input_digest`/`output_digest`/`redaction_digest`, `matched_rule_ids`, `policy_decision_ids`, `evidence_ids`, correlation and trace ids, the retention classes | Model, instrument, zone or answer fields. Unbuilt as a struct; `Ledger.Fragment` carries a map placeholder |
| AshEvents wrappers | `deps/ash_events/lib/events/{create,update,destroy}_action_wrapper.ex`, `replay_change_wrapper.ex` | Audit of create/update/destroy. On replay, change *hooks* are stripped and change *bodies* run. `create_timestamp` attributes are restored on replay (Q10, settled by AST-88's live replay test) | Generic-action audit |
| `ash_decisions` | `lib/ash_decisions/resources/definition.ex`, `evaluation.ex`; **matched-rule recording `787fa47` is inside the pinned `040ce6d`; the bump landed 2026-09-28 (`f1f5545`)** — v0's "lock predates" note was stale and is corrected here (A1) | The band table and a recorded evaluation of it, **with `matched_rule_ids` populated from the row** (the host banding step `d582f88` reads it; empty is a refusal, §7.1) | A link to a calibration run — that link is this RFC's certification record (§8.2, landed) |
| `ash_judgments` | `ca9b6cb`: `Ledger.Fragment`/`HumanVerdict.Fragment` (`3959aba`), `Cache` (`f6e8d6c`), `Banding.Fragment`/`CertificationFragment` (`e3639a3`), `Facts.Fragment`/`Materialiser`/`Query` (`9b2d101`), `Calibration.Fragment`/`SampleFragment` (`ca9b6cb`), telemetry (`6166183`) | The executable halves of §5–§8 — each section names its fragment as contract-of-record | Nothing downstream of the records (policies, triggers, UI) |
| `ash_rules` | `ede91fd` set evaluator; `2e25647` standings | The §7.4 consumer: three-valued set membership over the facts table; four membership-change event kinds (Q22) | — |
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
- **Exploratory namespace (v1, A6).** Undeclared questions (§7.4 n.5) occupy one reserved namespace per subject
  resource: `judgment:v0:<Module>#judgments/exploratory`. Declared questions are slot-identified; exploratory
  questions are content-identified — the ad-hoc `question_hash` (the §3.2 shape at `version: 1`, exactly as run) plus
  `wire_question_hash` (§3.3) is the identity and the recurrence key. Consumers treat the namespace id as opaque but
  groupable.

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
  `state_contract` (**Q1, settled as proposed**: the digest of the *declared shape* of the state projection's output).
  A projection change that alters what the model can see alters the shape and mints a new question; a refactor that
  does not alter the shape does not. The residual hazard — a content change with an unchanged shape — is accepted.
- `family` is **not** in the hash (Q3, settled as proposed). It is a calibration grouping; moving a question between
  families is a governance act recorded on the question record.
- Lineage (`parent_hash`, `proposer`, `proposer_version`, `proposal_id`) is **not** in the hash (ADR 0039 property 2;
  ADR 0047 point 1).
- For `Choice`, `options` is the ordered option list derived from the `of` enum or `one_of`. For `Score`, it is the
  ordered level list. For `Noul`, it is `[true, false]`. For `Extraction` (landed, `9b36394`), `options` is the status
  enum `["found", "not_found", "ambiguous"]` and the declared value schema rides `criteria` verbatim — identity covers
  wording, status vocabulary and value type with no change to this object's shape.

### 3.3 Wire question hash (what was actually sent)

Runtime questions exist. A matrix action supplies instructions per element through `questions:`
(`evaluate.ex` "Dynamic questions"), and a `Choice` may receive a runtime subset of its options. So the declared
question and the question sent can differ.

`wire_question_hash` = digest of the canonical JSON of the exact question object sent for this question id, after
`Answer.to_question/3` (for example `{"type":"choice","instructions":…,"criteria":…}`), taken before the provider's
own normalisation. **The key is required on every observation; the value is nullable — required non-null at the
decision rung** (v1, A2, resolving v0's §3.3/§5.2 tension as landed in AST-89). Generative observations carry it when
a wire question object is rendered — the extraction type renders one. `question_hash` identifies the declaration;
`wire_question_hash` identifies the call. The cache key uses the wire hash (§4.4).

This is the decision-rung analogue of ADR 0046's `wire_schema_hash` for the generative rung.

### 3.4 The question record (a registry entry)

The registry is DSL, so the compiled declaration is the source of truth (`AshJudgments.Registry`, AST-87). The
judgments package also materialises one append-only **question record** per `(question_id, question_hash)` the first
time it is activated, so the ledger can join to a row rather than to code that may have changed since.

| Field | Type | Req | Notes |
|---|---|---|---|
| `question_id` | string | yes | §3.1 |
| `question_hash` | digest | yes | §3.2 |
| `question_version` | integer | yes | The declared `version`. Monotonic per `question_id`. Two different hashes under one version is a registry error at compile time |
| `family` | string | yes | Calibration grouping (ADR 0041). Generic example: `clinic.notes_completeness` |
| `answer_type` | string | yes | Module name |
| `declaration` | object | yes | The exact object hashed in §3.2. Question wording is policy (DEC-MOAT), so this field is envelope-class but *deployment-private*: never exported to a public artefact. See §9 |
| `pin` | enum `required` \| `preferred` | yes | `required` for any family that can feed an admitted fact (ADR 0040). Default `required` |
| `must_record` | boolean | yes | ADR 0040 must-record vs best-effort. `true` for any family that can feed a fact; tooling families (ADR 0045) may be `false` |
| `data_class_ceiling` | enum | yes | The highest data class this question may be asked over (§5.4) |
| `cache_ttl` | ISO-8601 duration \| null | yes | Per family (ADR 0040; family TTL landed with AST-91, `ttl 0` = never reuse). `null` means never reuse |
| `lineage` | object \| null | no | `parent_hash`, `proposer` (`person:<id>` \| `optimiser:<name>` \| `distillation:<name>` \| **`search:<detector>@<version>`** — v1, A3: search-demand recurrence earns a structured proposer spelling; S1-56 records the promoting person as proposer meanwhile), `proposer_version`, `proposal_id` (ADR 0047). Non-identity |
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
- **Full length (64 hex characters, 256 bits) for every digest defined in this RFC** (Q4, settled as proposed):
  `question_hash`, `wire_question_hash`, `wire_schema_hash`, `state_contract`, `input_hash`, `cache_key`,
  `record_hash` and the evaluation-set hashes. Digests this RFC *copies* from elsewhere keep their source's format
  unchanged: a model digest as the runtime reports it (bare hex per `/api/tags`), and `ash_decisions`
  `content_hash` as stored. The envelope adopts 256 bits too, so one implementation serves both.
- The digest of nothing is `null`, never the digest of `{}` (envelope §2.4 rule 4).
- Digest the normalised form (envelope §2.4 rule 1). For state, that is the exact JSON body sent on the wire: the state
  after projection and `Ash.Type.dump_to_embedded`, as `evaluate.ex` `default_state/1` builds it.

### 4.3 Canonical JSON

Semantic-manifest §7.2 applies verbatim (UTF-8, sorted keys, no whitespace, integers only, atoms as strings, explicit
`null`, arrays in order), with one rule made explicit, and one v1 precision:

- **Probabilities, confidences, Score values and every other real number are decimal strings**, for example
  `"0.9412"`. §7.2 rule 4 forbids floats because float round-tripping is not portable. **The canonical form (Q5,
  settled v1, A4): the shortest decimal that round-trips the IEEE-754 double the runtime returned, rendered
  positionally.** The encoder computes in `Decimal` (`:erlang.float_to_binary(x, [:short])` for the round-trip
  decision, `Decimal` for the rendering), so scientific notation is **never emitted** — including derived values such
  as a Noul's `1 − p`, which honestly renders as e.g. `"0.09999999999999998"` and **conforms** to the schema's
  positional pattern. The string is never rounded to a display precision. Postgres stores it as `numeric`. The
  band-table bridge hands it to FEEL as a `Decimal`. A fixture pins the `1 − p` artifact so the pattern and the rule
  are tested together (added at v1 freeze; no v0 fixture changes).
- Distribution keys are the option values as strings (`"supports"`), or level indices as decimal strings (`"0"`,
  `"1"`) for `Score`, matching `Choice.probabilities` and `Score.probabilities`.

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

- This is seams §3.4 and ADR 0040, sharpened: the *wire* question hash, the runtime version, and the zone.
- **Runtime version is in the key** (Q6, settled as proposed; S1-21 observed it vary across a single routed fleet).
- **Tenant is not in the key; tenancy is enforced by the lookup.** The ledger is a tenant-scoped platform resource.
- A cache hit **writes no observation**. The caller references the existing observation id. The key and TTL decide
  reuse. A hit on a row whose `answered_at + cache_ttl` has passed is a miss.
- **Implemented as frozen** (v1 note, A5): the full key is `AshJudgments.Cache.key/1` (AST-89, `f6e8d6c`),
  superseding the ledger fragment's interim triple. TTL-live lookup, replay-miss refusal and shadow diffing are landed
  on the same path.

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
| `evidence_ids` | Candidate atoms are *not* here; they are in `judgment.input` (§5.4). `evidence_ids` names durable artefacts consulted — for an extract→verify pair, the verification observation carries `observation:<extraction-uuid>` here |
| `correlation_id`, `process_instance_id`, `trace_id`, `span_id`, `depth` | Unchanged. A pipeline shares one `correlation_id` across its calls |

Actor and grant, added by this RFC:

| Field | Type | Req | Notes |
|---|---|---|---|
| `automation_principal` | string \| null | no | Set when the call was made by an automation principal (ADR 0043). Mutually exclusive with `system_actor` for the same row |
| `grant_ref` | object \| null | no | For an automation principal: `{grant_id, role, privilege, family, risk_tier}`. For a human actor: `null`; their authority is in `policy_decision_ids` |

Question block:

| Field | Type | Req | Notes |
|---|---|---|---|
| `question_id` | string (§3.1) | yes | The exploratory namespace id for undeclared questions (§3.1, §7.4 n.5) |
| `question_hash` | digest (§3.2) | yes | For exploratory rows, the ad-hoc identity object's digest |
| `question_version` | integer | yes | `1` for exploratory rows |
| `family` | string \| null | yes | **Nullable (v1, A6): null iff `question.exploratory = true`** (§7.4 n.5). Non-null and required for declared questions. v0 §5.2's "required" and §7.4 n.5's "no family" disagreed; §7.4 governs and v1 states it here |
| `wire_question_hash` | digest \| null | decision rung: non-null | §3.3. Key required, value nullable; non-null at the decision rung (A2) |
| `question_set_hash` | digest | yes | Digest of the sorted list of `question_hash` values asked in the same request. This is law 6's "question-set hash" |

### 5.3 Instrument

| Field | Type | Req | Notes |
|---|---|---|---|
| `profile` | string | yes | The named profile the host resolved (ADR 0039: profile resolution is host code; `AshJudgments.Profile`) |
| `rung` | enum `decision` \| `generative` \| `emulated` | yes | `emulated` = typed decisions derived from an in-zone generative runtime's log-probs. A separate calibration family, never pooled (ADR 0042) |
| `provider` | string | yes | The `req_llm` provider id, e.g. `typesafe` for an Ollaya-served decision model |
| `model_spec_requested` | string | yes | The model name as requested, without `base_url` or keys (§9) |
| `model_reported` | string \| null | yes | `AshAi.Actions.Result.model`: what the runtime said answered |
| `model_digest` | string \| null | yes | The content digest of the model weights as the runtime reports it. **Q7 (settled, S1-21 live run): taken at call time from the loaded model's `/api/ps` entry, falling back to `/api/tags`** — the decide reply carries only the name. Required non-null when the question's `pin` is `required`. A runtime that stops exposing a digest disables `pin: required` families for admission until it does again (fail closed) |
| `runtime` | string | yes | e.g. `ollaya`, `llama.cpp`, `ollama`, `vllm` |
| `runtime_version` | string | yes | Pinned version as reported by the runtime. In the cache key (Q6) |
| `accelerator` | enum `gpu` \| `cpu` \| `unknown` | yes | What actually executed; `/api/ps`'s device field feeds it. Observations with a different accelerator than the calibration run's are flagged at banding (Q8) |
| `wire_spec_version` | string \| null | no | The wire compatibility version the runtime declares (ADR 0042 contract tests) |
| `wire_schema_hash` | digest \| null | generative: yes | ADR 0046 point 6. The exact JSON Schema sent, after per-call narrowing |
| `sampling` | object \| null | generative: yes | Temperature, seed, top-p and similar, as sent. `null` for the decision rung |
| `zone_id` | string | yes | The zone the instrument runs in. Must equal `judgment.input.zone_id` or the call is a disclosure and never an instrument call (ADR 0042) |

`residency` (`in_cluster` \| `sub_processor`) is **derived, not authoritative** (ADR 0042): `in_cluster` means the
instrument's zone equals the data's zone, and no out-of-zone instrument exists (DEC-HOSTED). **v1 (A7): the ledger
fragment stores it as a derived denormalisation** (default `:in_cluster`, recomputable from zone equality, never
authoritative) — blessed as landed; it costs one attribute and simplifies zone-partitioned reads.

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
| `retrieval` | object \| null | no | `{embedder_profile, embedder_digest, index_version}` when retrieval chose the atoms. **Provenance only; not in the cache key (Q14, settled)** |
| `data_class` | enum `public` \| `synthetic` \| `internal` \| `customer_confidential` | yes | ADR 0042. Must be at or below both the zone ceiling and the question's `data_class_ceiling` |
| `residency_restriction` | string \| null | yes | The source data's residency tag. A row with an unknown tag cannot exist, because untagged data never entered the zone |
| `zone_id` | string | yes | The data's zone |
| `jurisdiction` | string | yes | Denormalised from the zone record at write time, so every metric can split by it without a join (law 10) |
| `state` | JSON \| null | no | **Payload class** (§10). The state itself. `null` after erasure or when the family retains digests only |

**The state is absent from the envelope class, always.** Only `input_hash` and `state_ref` are envelope-class.

**Retrieval conventions (v1, A8).** The `retrieval` block is the complete retrieval provenance on the observation.
The **zone record** declares the zone's retrieval services: embedder profiles (name, model id, digest as reported,
dimensionality, metric), the index store, and the `index_version` lifecycle (a bump triggers reindex). Embeddings are
derived, erasable, **payload-class** data in the same zone as their sources; no cross-zone vector joins; moving
vectors out of a zone is an ADR 0026 disclosure with recorded authorization.

### 5.5 Answer

| Field | Type | Req | Notes |
|---|---|---|---|
| `outcome` | enum `answered` \| `cast_failed` \| `instrument_error` \| `timeout` \| `refused` | yes | A failure is still an observation (ADR 0046 point 3: a failed cast is recorded, never silently repaired). `refused` = **the runtime** declined, for example over-length state. A *host-side guard refusal* (pin mismatch, region mismatch, residency denial) happens before any call, writes no observation, and is telemetry (§5.5 note below) |
| `kind` | enum `noul` \| `choice` \| `score` \| `evidence` \| `extraction` | yes | Closed enum (§11). `evidence` is the proposed four-way `Choice` (ADR 0039); `extraction` is the generative rung (`AshJudgments.Evaluate.Extraction`, landed) — **distinct kinds, confirmed against the frozen schema** |
| `value` | JSON \| null | when answered | `Noul`: `null` (Q9). `Choice`/`evidence`: the option string. `Score`: the probability-weighted position as a decimal string. `extraction`: the cast value |
| `level` | string \| null | Score only | `Score.level` |
| `distribution` | object \| null | decision rung | Option (or level index) → decimal string. For `Noul`: `{"true": p, "false": 1 − p}`, derived from the single probability so every decision answer has the same shape. The runtime's own `probability` is kept verbatim in `raw` |
| `confidence` | decimal string \| null | Choice, Score, evidence | As returned. `Noul` has none. **`extraction` never has one** (ADR 0046 point 5; structurally absent in the landed type) |
| `status` | enum `found` \| `not_found` \| `ambiguous` \| null | extraction only | ADR 0044 extract → verify. Required on every answered extraction; `value` is non-null iff `status == "found"` |
| `source_ids` | [string] \| null | extraction, evidence | Atom ids only. For extraction, constrained on the wire to the packet's atom ids (per-call enum narrowing — CLIN-34: fabricated citations 0.0) |
| `selected_atom_ids`, `limiting_atom_ids`, `missing_dimensions` | [string] | evidence, when available | ADR 0044. v0 decision models do not return these; they are filled by the evidence pipeline's own steps (Q15) |
| `raw` | JSON \| null | no | **Payload class.** The runtime's raw answer for this question id, or the generative raw reply before the Ash cast |
| `logprobs` | object \| null | no | **Payload class.** Raw token log-probabilities where the runtime returns them (generative and emulated rungs only). Required for `emulated` |
| `error` | object \| null | on failure | `{class, message_digest}`. The message itself is payload class |

**Guard refusals are telemetry, not observations (v1, A9).** A profile-guard refusal — pin mismatch, region mismatch,
residency denial — occurs before any instrument call. It writes no observation row: manufacturing `instrument_error`
or `refused` for a call that never reached a runtime would misattribute a host guard to an instrument. The record is
the telemetry event: `[:ash_judgments, :record, :pin_mismatch]` and `[:ash_judgments, :residency, :denied]` (the
disclosure event; the endpoint is never named), landed with AST-90 (`6166183`).

**Disposition is not admission.** `evidence` values are `supports | contradicts | insufficient | not_applicable`,
plus the optional `wrong_scope`. Nothing on the observation says `admitted`, `review`, `compliant` or any other value
from another layer.

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

1. **Immutable.** No update action exists (erasure's one sanctioned update is the tombstone, §10). Re-inference is a
   new row (law 2).
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
- Change bodies may compute **pure** derived fields from inputs only: digests (`input_hash` from `state`,
  `record_hash`, `cache_key`), the `Noul` distribution from its probability, and the denormalised `jurisdiction` from
  a zone record *passed in* (not looked up). Given the same inputs, they give the same output on replay.
- `recorded_at` is the one database-generated field. **Q10 (settled by implementation, AST-88): `recorded_at` is the
  resource's `create_timestamp`, and AshEvents restores it on replay** — proven by the live replay test
  (byte-identical rebuild, zero extra model calls). The explicit-input alternative was not needed.
- Banding, admission, verdict and calibration records follow the same rule: every create accepts its computed result
  as input. The band-table evaluation happens before the create; its `ash_decisions` evaluation id is passed in.

### 6.2 What replay means for each consumer

| Consumer | Reads | Never does |
|---|---|---|
| AshEvents replay of the ledger | Recorded create inputs | Calls an instrument or evaluates a band table |
| `ash_events_projections` rebuild | Observation, banding and admission events | Calls an instrument (ADR 0038) |
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

**Modes are properties of the call site, not of the profile** (v1 note, A5; landed rationale, AST-89): the same
instrument profile may be invoked in any mode; the mode records how the call was made, and lives on the judge path
where the caller chooses it.

---

## 7. Banding, admission and human verdicts

### 7.1 Banding record

A banding says which band-table row an observation's answer fell into. It asserts nothing about the world and admits
nothing. **Contract-of-record (v1, A10): `AshJudgments.Banding.Fragment` (`e3639a3`)** — record-as-inputs, immutable;
the host banding pipeline (`d582f88`) runs flatten → resolver → evaluate → record.

| Field | Type | Req | Notes |
|---|---|---|---|
| `id`, `record_hash`, envelope core | | yes | The actor is whoever ran the banding step |
| `observation_ids` | [uuid] | yes | Usually one. More than one when a band table reads several answers — e.g. an extraction plus its verification (§5.5) |
| `band_table` | object | yes | `{definition_key, definition_version, content_hash, definition_id, tenant_fork}`, copied from `ash_decisions` `Definition` at evaluation time |
| `decision_evaluation_id` | uuid | yes | The `ash_decisions` `Evaluation` row |
| `inputs` | object | yes | The flattened DMN inputs (probabilities as decimal strings, family, risk tier, jurisdiction). Envelope-class |
| `matched_rule_ids` | [string] | yes | From `Evaluation.matched_rule_ids`, **populated from the row** (in the pin; A1). **An empty list is a refusal, not a result** — enforced at the fragment boundary |
| `band` | enum `admit` \| `review` \| `omit` | yes | The band table's output (ADR 0041). The frozen enum |
| `fact_value` | JSON \| null | admit only | The fact value the table proposes |
| `mode` | enum `live` \| `shadow` | yes | |
| `flags` | [string] | no | e.g. `accelerator_mismatch`, `digest_missing`, `audit_sample_selected` |
| `banded_at` | timestamp | yes | |

### 7.2 Admission record

The admission is the action that turns a banding into a fact, a review task, or nothing. It is performed by a person
or by an automation principal holding a grant (ADR 0043). **No dedicated fragment: the admission action is host-side
(landed in the banding pipeline's routing, `d582f88`); its fact-writing semantics are the contract-of-record in
`AshJudgments.Facts.Materialiser` (`9b2d101`)** — the truth table below, as code.

| Field | Type | Req | Notes |
|---|---|---|---|
| `id`, `record_hash`, envelope core | | yes | |
| `banding_id` | uuid | yes | |
| `observation_ids` | [uuid] | yes | Denormalised |
| `result` | enum `admitted` \| `review` \| `omitted` | yes | `omitted`, not `unknown`: decided by Luke on 2026-09-28 (Q11) |
| `actor_kind` | enum `person` \| `automation_principal` | yes | Never a system actor with bypass; never the `ai` system actor (ADR 0043) |
| `grant_ref` | object | automation: yes | `{grant_id, role, privilege, family, risk_tier, tenant_id}`. The grant must name a question version whose calibration satisfies the optimise-split rule (ADR 0043) |
| `fact_ref` | object \| null | admitted | `{fact_id, subject, predicate, value}` of the fact written through the ordinary action |
| `review_task_ref` | object \| null | review | The human task opened |
| `audit_sample` | boolean | yes | `true` when routed to review by the random audit sample (ADR 0041) |
| `supersedes` | uuid \| null | no | A prior admission this replaces. Admitted facts are superseded, never edited (ADR 0044) |
| `effective_at` | timestamp | yes | |

Normative:

1. An automation principal with no matching grant row admits nothing (ADR 0043).
2. **Human entries win.** An automatic admission never overwrites or lowers a fact a person entered. It may only fill
   an absence.
3. `contradicts` never auto-admits a failing fact. It routes to review at any probability (DEC-AUTONOMY).
4. `omitted` writes no fact — **and supersedes the current fact, writing no replacement** (v1, A11): the predicate
   returns to `unknown` for every consumer. So `missing: :unknown` evaluates to `unknown` in ash_rules. Uncertainty
   never collapses to compliant.

### 7.3 Human verdict record

**Contract-of-record (v1, A10): `AshJudgments.HumanVerdict.Fragment` (`3959aba`).**

| Field | Type | Req | Notes |
|---|---|---|---|
| `id`, `record_hash`, envelope core | | yes | The actor is the reviewer |
| `observation_id` | uuid | yes | |
| `question_hash`, `model_digest`, `input_hash`, `state_ref` | | yes | Denormalised from the observation |
| `model_answer` | object | yes | The observation's `kind`, `value` and `distribution` (an extraction's `status` is reachable via `observation_id`) |
| `human_answer` | JSON | yes | In the question's own answer space (an option, a level, `true`/`false`, or an extracted value — for extraction, the correct typed value plus status) |
| `basis` | enum `review_task` \| `audit_sample` \| `labelling` \| `override` | yes | Keeps the sample's selection visible (ADR 0047 point 8) |
| `labelling_protocol` | string \| null | labelling | Protocol version; **states provenance-marker handling** (CLIN-34's "(fictional)" lesson) |
| `double_label_of` | uuid \| null | no | For inter-rater agreement |
| `split` | enum `optimise` \| `calibration` \| `test` \| `audit` \| null | labelling | Assigned by source document, disjoint (ADR 0041; split machinery landed, S1-25 §6) |
| `note` | string \| null | no | **Payload class.** Free text from a reviewer can quote a document |


### 7.4 The fact, as sets read it (ADR 0048)

ADR 0048 (accepted 2026-10-02) makes admitted facts the vocabulary of filters, search, segments and standing queries,
not only of rules. A set reads facts in bulk, in SQL, with no model in the path. **Contract-of-record (v2 draft):
`AshJudgments.Facts.TemporalFragment` + `AshJudgments.Facts.Materialiser` (temporal mode) + `AshJudgments.Query`**
(ash_judgments AST-147) — **the v1 contract (`Facts.Fragment` + `Facts.Materialiser` + `Query`, `9b2d101`, v1 A10)
remains the frozen contract of record until this draft freezes.** The consumer is `AshRules.Evaluator.Set`
(`ede91fd`) with its equivalence property test.

Every fact written by an admission (§7.2 `fact_ref`), and every fact a person enters directly, carries:

| Field | Type | Req | Notes |
|---|---|---|---|
| `subject` | JSON | yes | **The composite subject term `{"type", "id"}`** (v1, A11) — opaque to consumers, JSON-encoded so data-layer equality stays a superset of the IR's strict equality |
| `subject_type`, `subject_id` | string, string | yes | Denormalised from `subject` (pure derivation, replay-identical). Indexed together with `predicate` |
| `predicate` | string | yes | The question id (§3.1) for a judged predicate, or the fact-schema name for a crisp one; one namespace |
| `value` | JSON | yes | In the predicate's declared type. **Scalars stored as scalar JSON** (`true`, `"urgent"`, `80`) — v1, A11; wrapper maps only for genuinely composite values (extraction structs) |
| `holds` | boolean | yes | **Stored (v1, A11): the membership reading of the value, fixed at materialisation** — `true` = in, `false` = out. The tri-state surface reads it; IR probes read `value` |
| `scope` | object \| null | yes | `null` for a fact about the subject alone. Otherwise the context it holds in. A filter always runs in the actor's scope |
| `subject_state_digest` | digest \| null | judged: yes | The digest of the state projection the question saw. When the subject's current projection digest differs, the fact is **stale** |
| `valid_until` | timestamp \| null | no | Declared per predicate. An expired fact is `unknown` |
| `admission_grade` | enum `person` \| `grant` | yes | Who admitted it (Q19, settled: one fact carries its grade). Consumers state the minimum grade they accept — **default floor `:grant`** (v1, A11) |
| `admission_id` | uuid \| null | judged: yes | Back-reference for provenance on every search hit |
| `valid_at` | period | yes | **The record-validity period (v2, replaces `superseded_by`)** — which assertion is current, not when the domain claim expires. "Current" means the open period contains now, derived by the as-of-now read; no stored pointer, no collapsed boolean. A revision **splits the period at the admission's `effective_at`**; an omission **truncates the period at `effective_at`, writing no replacement** (§7.2 n.4, verbatim) — history preserved, the predicate returns to `unknown`. The second time axis is untouched: `valid_until` stays an attribute, and an expired fact still resolves to its row |
| `scope_hash` | digest | yes | **The identity key (v2)** for the `WITHOUT OVERLAPS` exclusion constraint. Digest (§4.2) of the canonical JSON (§4.3) of `scope` — pure, replay-identical, same derivation discipline as `DeriveSubject`; canonical JSON's explicit `null` keeps the digest defined when `scope` is `null`, so the key is never null. `scope` is a map and cannot key an exclusion constraint; row identity is `(subject_type, subject_id, predicate, scope_hash)` |

Implementation notes (v2 — the temporal mechanism; these replace the supersede-then-create mechanics, not any
normative below):

- **As-of-now reads derive membership.** The default read is as-of-now, so "current" in normatives 1 and 4 is
  derived at read time: the open period containing now — exactly what `is_nil(superseded_by)` derived in v1. The
  `current?` calculation, the `:current` read filter and the `:supersede` action are deleted; `for_subject` becomes
  an as-of-scoped key lookup.
- **Revise = period split at `effective_at`.** One row identity per `(subject_type, subject_id, predicate,
  scope_hash)`. A revision closes the prior period at the new admission's `effective_at` and opens a new one
  carrying its own `value`, `holds`, `admission_grade` and `admission_id`. The v1 create-then-supersede dance is
  deleted.
- **Omission = period truncate at `effective_at`.** The `omitted` admission closes the open period, writing no
  replacement (§7.2 n.4): history is preserved and every consumer reads the predicate back to `unknown`.
- **`WITHOUT OVERLAPS` identity.** One open period per identity key, enforced by the database (Postgres 18 floor),
  replacing uniqueness-by-convention. The temporal split-write protocol (lock-and-recheck, `WriteConflict`) replaces
  the hand-rolled supersede-then-create transaction. **The materialiser remains the sole writer** — temporal owns
  how rows version; the materialiser's truth table (§7.2) owns why rows change.
- **Indexes (normative 4's implementation change).** The v1 partial index on current facts becomes the period index
  plus the `WITHOUT OVERLAPS` exclusion constraint; the set evaluator's plans remain part of its acceptance test.
- **Unchanged.** `valid_until` and expiry, `stale?`, `subject_state_digest`, `holds`, `value` and the full grade
  machinery carry over untouched; the `:superseded` status arm's consumer meaning ("not current") is preserved
  under period-closed derivation.

Normative:

1. **Membership is derived, never stored.** For a judged predicate, a subject is *in* when a current, fresh,
   unexpired fact in the actor's scope at or above the grade floor has the declared "holds" value, and *out* when it
   has the "does not hold" value. It is *unknown* otherwise: no fact, an `omitted` admission, a `review` task open,
   stale, expired, or below the grade floor. No record stores a boolean that could lose the third value.
2. **Freshness is checkable in SQL, and provable-only (v1, A11).** The host keeps each subject's current projection
   digest per question, updated in the same transaction as the subject's change, so staleness is a join, not a model
   call. A fact with no digest, and a fact with no known current digest, both read **fresh** — staleness is proved,
   never assumed. The change also enqueues reassessment.
3. **The set evaluator reads this table only.** It never reads observations for membership. Observations may be read
   only for labelled ordering (ADR 0048, "scores order; facts decide").
4. **Indexes.** At least `(predicate, scope, subject_type, subject_id)` and a partial index on current facts. The set
   evaluator's plans are part of its acceptance test.
5. **Exploratory observations** (ADR 0048: undeclared questions run over a bounded candidate set) are ordinary
   observations with `question.exploratory = true` and `family: null` (A6). They are never banded, never admitted,
   never used for calibration unless a person labels them, and they carry the shortest retention class (§10).
   **Conventions (v1, A6, S1-56 accepted defaults):** the exploratory namespace id (§3.1); the candidate-set bound —
   default 100 subjects per explicit run, hard cap 500; recurrence threshold K = 3, counted over **audited action
   invocations** grouped by `wire_question_hash` (cache hits write nothing, so ledger rows undercount); a person may
   always promote explicitly. Crossing K mints a question proposal whose proposer is the promoting person, with the
   detector recorded for the v1 `search:` spelling (§3.4).
6. **Standing queries are not judgment records** (Q22, answer standing; ratified vocabulary v1, A12): membership
   changes are ordinary platform events on the standing query's resource, referencing fact and admission ids. The
   ratified event vocabulary is **four kinds** — `entered`, `left`, `became_unknown`, `resolved_out` — because
   `unknown → out` is neither `left` (the subject was never in) nor silence (a real verdict change); events carry
   `from`/`to` so no consumer guesses (`AshRules.Standings`, `2e25647`).

## 8. Calibration runs and the band-table link

### 8.1 Calibration run record

One record per `(family, question_hash, model_digest, runtime_version, evaluation-set hash, zone)` (ADR 0041).
**Contract-of-record (v1, A10): `AshJudgments.Calibration.Fragment` + `SampleFragment` (`ca9b6cb`)** — decimal-string
metrics, replay-safe, band-table proposals at n-thresholds (never auto-certified), family TTL.

| Field | Type | Req | Notes |
|---|---|---|---|
| `id`, `record_hash`, envelope core | | yes | |
| `family` | string | yes | |
| `question_hashes` | [digest] | yes | Usually one |
| `question_lineage` | object | yes | Copied from the question record, including `proposal_id` and the `optimise_split_hash` (ADR 0041, 0047) |
| `instrument` | object | yes | The §5.3 fields that identify it |
| `zone_id`, `jurisdiction` | string | yes | A run in one jurisdiction does not license a band table in another (ADR 0042) |
| `eval_set` | object | yes | `{eval_set_id, eval_set_hash, split_hashes, label_set_hash, labelling_protocol}` |
| `n` | object | yes | Total, and per class, on the calibration split. The verifier compares it with the family's minimum n (landed: RiskControl min-n schedule) |
| `metrics` | object | yes | Reliability bins, ECE, Brier, per-class precision/recall at candidate thresholds, selective accuracy and coverage. All decimal strings. **For extraction families, the standard four (v1): exact-match on gold, fabricated-citation rate, false-abstention rate, valid-but-wrong-on-traps** (CLIN-34) |
| `observations_digest` | digest | yes | Digest of the sorted observation ids the run produced, so the run can be re-scored without re-inference |
| `result` | enum `proposed_table` \| `no_table` \| `regression` | yes | Negative results are kept (ADR 0047 point 7) |
| `proposed_band_table` | object \| null | no | `{definition_key, definition_version}` of the *draft* table the run produced |
| `pass_bar` | object | yes | The pre-registered pass bar and kill criteria (ADR 0047 point 7) |
| `started_at`, `finished_at` | timestamp | yes | |

The run's labelled items and their text are **not** in the record (the `SampleFragment` keeps live accumulation with
labels payload-class). They live in the zone's evaluation store and never in git, Plane or a public artefact
(DEC-MOAT; SYNTHESIS §8).

### 8.2 The band-table link

A band table is an `ash_decisions` `Definition` (DMN). That resource is upstream and generic, so this RFC does not add
fields to it. The link is a separate judgment-side record. **Contract-of-record (v1, A10):
`AshJudgments.CertificationFragment` (`e3639a3`)**, including revocation.

| Field | Type | Req | Notes |
|---|---|---|---|
| `id`, `record_hash`, envelope core | | yes | |
| `definition_id`, `definition_key`, `definition_version`, `content_hash` | | yes | The published definition |
| `family` | string | yes | |
| `calibration_run_id` | uuid | yes | |
| `model_digest`, `runtime_version` | string | yes | Must equal the run's |
| `optimise_split_disjoint` | boolean | yes | No calibration item intersects the optimise split used to produce the question version |
| `verifier_version` | string | yes | |
| `verified_at` | timestamp | yes | |

**Activation** is not a field here. It is the existing validate → approve → activate lifecycle, and its record names
the activating person, who is the **author of record** for the band table (ADR 0041). A banding record points at
`(definition_key, definition_version, content_hash)`. From there the chain is: certification → calibration run →
evaluation set hash, and activation → approver → effective date. That is ADR 0041's "why was this fact admitted?"
answer as joins.

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
6. **Deployment question wording in a public artefact.** The `declaration` field is envelope-class for retention but
   deployment-private for publication (DEC-MOAT). Public fixtures use synthetic wording only.
7. **Customer content in fixtures, tests, transcripts, Plane or commits.** Fixtures are synthetic and CC0.
8. **US-only restricted data, or any data whose residency tag the zone cannot satisfy.** It never entered the zone, so
   it cannot be in a row (ADR 0042 admission rule).

---

## 10. Stores and retention (answering docs-s1 C10)

**Decision: the judgment ledger is its own set of tables, not the domain event log.**

- Observations are high volume: one per question per call, with calibration and shadow runs multiplying that.
  Consequential domain events should not carry them (docs-s1 C10, the D3 position).
- Each ledger record is written by a **create action on a host resource built on `AshEnterprise.Platform.Resource`**
  (ADR 0040; landed, `9fad00e`), so AshEvents audits it, and tenancy, correlation and policies are inherited. Opting
  a high-volume family out of AshEvents audit is explicit and local, and **never permitted for a family that can feed
  a fact**.
- **Domain events carry summaries and ids only.**

Retention classes, extending envelope §2.7:

| Class | Fields | Retention | Erasure |
|---|---|---|---|
| **Envelope** | Everything not listed below: ids, digests, versions, codes, decimal-string probabilities, timestamps, refs | Indefinite | Nothing personal to erase by construction |
| **Payload** | `input.state`, `answer.raw`, `answer.logprobs`, `answer.error` message, `human_verdict.note`, calibration sample labels, embeddings (§5.4) | Per zone and tenant policy; per family (`digest_only` families never store it); exploratory rows shortest (30 days proposed operationally) | Erasable. Erasure sets the field to `null` and writes a tombstone record. `record_hash` still verifies (§4.5). The `:tombstone_state` action is landed (`3959aba`); time partitioning remains deferred (E6) |
| **Evidence blob** | Documents, atoms' text, exports | Compliance programme | Erasable. Erasing a document leaves `document_version_hash` and atom ids valid as references to something that no longer resolves; its vectors go with it (§5.4) |

**Erasure versus replay (SYNTHESIS §7 Q7, ADR 0024).** Replay reads the answer, not the state, so it survives erasure.
What erasure costs is shadow evaluation and re-calibration over the erased subject, which is the correct loss.

---

## 11. Versioning and compatibility (normative)

- Every record carries `record_version`, a major version only: `"0"`. This follows semantic-manifest §6.1.
- **Additive within a major version**: a new optional field, a new value on an open enum (`outcome`, `flags`,
  `basis`, `runtime`, the lineage proposer spellings — A3), or populating a field that was always `null`. **The
  family-null widening (A6) is additive in effect**: it applies only to exploratory rows, which v0 never produced;
  no v0 row changes meaning.
- **Closed enums** (changing them is breaking): `kind`, `mode`, `band`, `result`, `data_class`, `rung`, and the
  disposition values.
- **Breaking, requiring `"1"`**: removing or renaming a field; changing a field's JSON type; changing the
  `question_hash`, `wire_question_hash`, `cache_key` or `record_hash` input subsets; changing the digest algorithm or
  length; changing the canonical-JSON rules or the decimal-string rule; moving a field between the envelope and
  payload classes. **v1 changes none of these** — every amendment is text-level or additive.
- Consumers ignore unknown fields and treat unknown values of open enums as opaque.

---

## 12. Examples (synthetic clinic)

Digests below are shortened placeholders (`sha256:9f2c…`), not real hashes. The frozen fixture set — six synthetic
CC0 records under `test/fixtures/judgment_record/`, including the extraction-generative observation — is the golden
test; a v1 freeze adds the `1 − p` decimal fixture (§4.3) alongside them.

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
      "model_digest": "…as the runtime reports it",
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
date is 2027-03-31?", carrying `evidence_ids: ["observation:<extraction-id>"]` and sharing the pipeline's
`correlation_id`. The banding record lists both observation ids.

**A replay hit.** In replay mode no record is written. The caller receives the existing observation id.

**An erased state.** `input.state: null`, `answer.raw: null`, a tombstone record naming both fields, and an
unchanged `record_hash`.

---

## 13. Open questions and their statuses

Numbered for reference. Settled items carry their answer and provenance; open items carry v0's proposed position.

**From this RFC**

- **Q1. Is the state projection part of `question_hash`?** **Settled as proposed** — yes, as the digest of the
  projection's declared output shape (`state_contract`). Residual hazard (content change with unchanged shape)
  accepted. Landed: `Registry.Canonical.state_contract/1`.
- **Q2. Should `judgment:` join `dmn:` and `bpmn:` as schemes proposed back to the semantic-manifest RFC?** *Open.*
  Proposed: yes, all three together.
- **Q3. Is `family` outside the hash?** **Settled as proposed** — yes; family moves are recorded on the question
  record.
- **Q4. Digest length.** **Settled as proposed** — 256 bits for every digest this RFC defines; the envelope adopts
  256 too; the manifest keeps 128.
- **Q5. Decimal-string precision.** **Settled (v1, A4)** — shortest round-trip, rendered positionally via `Decimal`;
  scientific notation never emitted; the schema's positional pattern stands; a `1 − p` fixture pins the artifact.
- **Q6. Runtime version in the cache key?** **Settled as proposed** — yes (S1-21 observed version vary across a
  routed fleet).
- **Q7. Where does `model_digest` come from?** **Answered 2026-10-02 by S1-21's live run** — over HTTP at call time:
  `/api/ps` (loaded, with device) falling back to `/api/tags`. Corollaries: the device field feeds Q8's accelerator
  flagging; a runtime that stops exposing a digest disables `pin: required` admission until it does again.
- **Q8. Accelerator mismatch.** *Open, position unchanged*: flagged, and refused for `admit` bands.
- **Q9. Noul `value`.** **Settled as proposed** — `value: null` and a two-way `distribution`; landed in the
  `:record` change.
- **Q10. `recorded_at` on replay.** **Settled by implementation (AST-88)** — the resource's `create_timestamp`;
  AshEvents restores it on replay; proven by the live replay test.
- **Q11. The admission value `omitted` vs `unknown`.** **Settled 2026-09-28** — `omitted`; `unknown` is an ash_rules
  outcome.
- **Q12. Cache-hit usage records.** *Open, position unchanged*: no; the consuming admission already references the
  observation.
- **Q13. Must-record failure semantics.** **Settled-confirm (v1)** — fail closed: in a must-record family, a ledger
  insert failure after a successful call discards the answer and returns an error. Landed in the recorder (AST-88).
- **Q14. Retrieval provenance.** **Settled** — provenance only in v0/v1: not identity, not in the cache key
  (implemented as such). Revisit when `ash_evidence` lands.
- **Q15. Evidence assertion: the observation or its own record?** *Open, position unchanged*: a separate
  `ash_evidence` assertion record; the v0 observation carries the optional fields.
- **Q16. Question-record materialisation.** *Open, position unchanged*: at activation.
- **Q17. Profile record.** *Open, position unchanged*: not yet; repeat the fields.
- **Q18. Jurisdiction codes.** *Open, position unchanged*: ISO 3166-2 proposed; the zone record owns the code.
- **Q19. Does admission grade vary by consumer?** **Settled (S1-52, 2026-10-02)** — one fact per predicate and scope
  carries `admission_grade` (`person | grant`); each consumer states its minimum at request time (default `:grant`).
  Not a band table per consumer. (This is SYNTHESIS §7's Q13.)
- **Q20. Staleness granularity.** **Settled as proposed, confirmed by implementation** — the state projection's
  digest, not any field; landed (`Facts.Stale`, provable-only, A11).
- **Q21. Where facts live.** **Settled as proposed, confirmed by implementation** — one host facts table keyed by
  subject/predicate/scope (`Facts.Fragment`, `9b2d101`); per-resource columns only as a measured optimisation.
- **Q22. Standing-query events.** **Superseded by usage (v1, A12)** — still not a judgment record (an ordinary
  platform event on the standing query's resource, referencing fact and admission ids), but the vocabulary is
  **four kinds** — `entered / left / became_unknown / resolved_out` — ratified as landed (`AshRules.Standings`,
  `2e25647`): `unknown → out` is a real change and must not fold law 14 either way.

**The provenance envelope's own open questions (envelope §4.1–§4.6)**

- **E1** its own table — settled for judgments (the ledger is its own table, landed); the general envelope case
  deferred to AST-9. **E2** truncation — see Q4. **E3** `policy_decision_ids` for reads — deferred to AST-9.
  **E4** composition `semantic_id` — settled for judgments (one observation per question, shared `request_id`);
  general case deferred. **E5** `dmn:`/`bpmn:` schemes — see Q2. **E6** retention enforcement — classes defined
  (§10); the tombstone action is landed, time partitioning still deferred to a host migration.

**The six Lane G questions (wip-ast §2, AST-9)** — G1, G2 deferred to AST-9; G3 settled for judgments (the process
reads the ledger by `cache_key` in cache mode; restart is replay-safe); G4 settled additively (the engine and version
ride the banding record's `band_table` object); G5 see Q4; G6 deferred.

---

## 14. Exit criteria for freezing v1

| AC | Kind | State of this draft |
|---|---|---|
| AC-1: every A-item applied in place; no §11-breaking change introduced | manual | Done — Appendix A maps each |
| AC-2: no contradiction with any landed implementation at its cited commit | manual | Done — §2, §4.4, §5, §7–§8 carry the pointers |
| AC-3: schema and fixture bytes unchanged from v0; the `1 − p` fixture added | static | Fixture added at freeze; golden pins extended |
| AC-4: Q roll-up integrated (§13), open questions still open | manual | Done |
| AC-5: Luke marks v1 accepted | manual | **Closed 2026-10-05** — "Approved. Freeze Go." (S1-24 comment + in-chat) |

---

## 15. Public home and layout

1. The frozen v0 lives at `ash_enterprise/docs/rfc/judgment-record-v0.md` with its schema and fixtures. **The
   layout (v1, A13) is the contract, blessed**: the schema at `priv/judgment_record/schema.json` (read at compile
   time by `AshEnterprise.JudgmentRecord` via `@external_resource`, law 16), fixtures at
   `test/fixtures/judgment_record/`, golden pins + frozen-marker sentinel in
   `test/ash_enterprise/judgment_record_golden_test.exs`, and the review pack at
   `docs/rfc/judgment-record-v0-review-pack.md`. §15's nominal `docs/rfc/fixtures/judgment/` path is retired.
2. On freeze, this text moves to `ash_enterprise/docs/rfc/judgment-record-v1.md`; v0's public copy, schema and
   fixtures stay byte-untouched.
3. The provenance-envelope doc carries the v0 supersession banner already; v1 adds nothing there.

---

## 16. Diff against seams §3.3 (v0's AC-3, carried forward unchanged)

| seams §3.3 field | Here | Note |
|---|---|---|
| `question_id`, `question_hash`, `question_version`, `family` | §5.2 question block | Plus `wire_question_hash`, `question_set_hash` |
| `subject_type` / `subject_id` | §5.4 | Also inside `state_ref` |
| `rule_id`, `predicate_id` | §5.4 `rule_ref` | Plus `bundle_hash` |
| `chunk_id` | §5.4 `candidate_atom_ids` | Renamed: atoms, not chunks (ADR 0044) |
| `document_hash` | §5.4 `document_version_hash` | |
| `state_hash` | §5.4 `input_hash` (= envelope `input_digest`) | |
| `state` | §5.4 `state`, payload class | Encryption deferred in-zone |
| `answer`, `value`, `probabilities`, `confidence` | §5.5 | `probabilities` → `distribution`, decimal strings |
| `model_spec`, `model_version` | §5.3 `model_spec_requested`, `model_reported` | Plus `model_digest`, `runtime`, `runtime_version`, `accelerator` |
| `profile` | §5.3 | |
| `residency` | **Dropped** (derived) | Replaced by `zone_id`, `jurisdiction`, `data_class`, `residency_restriction`; the fragment's derived denormalisation blessed (§5.3) |
| `usage`, `latency_us` | §5.6 | Request-scoped |
| `cache_key` | §4.4, §5.6 | Wire question hash, runtime version and zone added |
| `correlation_id` | envelope core | |
| `organization_id` (tenant) | envelope `tenant_id` | |
| `band`, `band_table_ref` | **Moved** to the banding record, §7.1 | |
| (new) region | §5.4 `jurisdiction` + `zone_id` | |
| (new) mode | §5.6 | `live | shadow | calibration | eval` |
| (new) wire schema hash, raw reply, grammar runtime | §5.3, §5.5 | ADR 0046 |
| (new) raw log-probs | §5.5 `logprobs`, payload class | |
| (new) actor and grant | §5.2 | `automation_principal`, `grant_ref` |
| `HumanVerdict` | §7.3 | |

---

## 17. Changelog

- **Revision 1 (2026-09-28).** First draft.
- **Revisions 2–4 (2026-09-28 / 2026-10-02).** §7.4 fold (Q19–Q22); Q11 settled; Q7 answered from S1-21's live run;
  the freeze (AC-6 closed 2026-10-02 14:37/14:39 UTC).
- **Revision v1 (2026-10-02).** The errata consolidation applied in place (A1–A13; three forks at recommended
  defaults: A4 positional decimal rendering, A7 residency as blessed denormalisation, A9 guard refusals
  telemetry-only). Q5/Q13/Q14/Q20/Q21 marked settled; Q10/Q22 settled-by-implementation; A12 ratified; layout
  blessed; §7–§8 fragments named contract-of-record. Base: v0 sha256 70eb8192…f160. Sources:
  `rfc/S1-24-v1-errata-consolidation.md`, the landed substrate (§ header), RESUME.md's errata trail.
- **Revision v2 (DRAFT, 2026-10-07). NOT FROZEN — v1 remains the contract of record until Luke's freeze gate.**
  Per S1-68 and the AST-146 temporal-swap design note (green-light 2026-10-07): §7.4 field-table swap
  (`superseded_by` out; `valid_at` period + `scope_hash` in), §7.4 implementation notes rewritten to the temporal
  mechanism, every §7.4 normative and §7.2 rule carried verbatim, §11-based breaking-change declaration and the
  v2 audit trail in Appendix B. Base: v1 at freeze. Source: `research/facts-temporal-swap-design.md`.

---

## Appendix A — Audit trail

### A.1 No-change confirmations (audited against the frozen schema and the landed code)

1. **The `kind` enum carries both `evidence` and `extraction` as distinct kinds.** The S1-61 and AST-95 flags to the
   contrary were retracted after checking the frozen schema; the real defect (`Ledger.Fragment`'s `answer_kind`
   one_of missing `:extraction`) was fixed at `9b36394`. No change.
2. **`admission_result`** (`admitted | review | omitted`) matches Q11; the AST-92 stub doc's contrary spelling was
   corrected toward the frozen record before landing — the record was never wrong.
3. **The extraction conditionals** (`status` required, `confidence` const-null, `wire_schema_hash`+`sampling` at the
   generative rung) — the landed type conforms; the CC0 fixture validates unchanged.
4. **The §4.4 cache key as frozen** is implemented verbatim (`Cache.key/1`); AST-88's interim triples superseded.
5. **§7.4 normatives 1–4** — no semantic drift; A11's items are conventions within the fields.
6. **Q9's noul shape** — implemented as frozen.
7. **Honest `1−p` artifacts** (`"0.09999999999999998"`) conform to the frozen positional pattern; only scientific
   extremes were ever at risk (A4).

### A.2 Amendment → section map (diff v1 against v0 by intent)

| Item | Section(s) edited | In one line |
|---|---|---|
| A1 | §2 | ash_decisions row: matched-rule recording is in the pin; v0's "lock predates" was stale |
| A2 | §3.3, §5.2 | `wire_question_hash`: key required, value nullable, non-null at decision rung |
| A3 | §3.4 | lineage proposer gains `search:<detector>@<version>` |
| A4 | §4.3, §12, §14 | decimal: shortest round-trip rendered positionally via Decimal; fixture pinned; Q5 settled |
| A5 | §4.4, §6.3 | cache key implemented-as-frozen (`Cache.key/1`); modes are call-site properties |
| A6 | §3.1, §5.2, §7.4 n.5 | family nullable iff exploratory; namespace; bounds 100/500; K=3 over audited invocations |
| A7 | §5.3 | residency blessed as a derived denormalisation |
| A8 | §5.4 | retrieval conventions: block complete, zone-record services, vectors payload-class in-zone |
| A9 | §5.5 | host guard refusals are telemetry, never observations |
| A10 | §7.1, §7.2, §7.3, §7.4, §8.1, §8.2, §2 | landed fragments named contract-of-record |
| A11 | §7.4 | composite subject, stored `holds`, scalar values, omission-supersedes, fresh-on-unknown-digest, floor `:grant` |
| A12 | §7.4 n.6, §13 Q22 | fourth standing-query kind `:resolved_out` ratified |
| A13 | §15 | actual layout blessed; nominal path retired |

*Cross-check: v1 contradicts no landed implementation at its cited commit; v0's frozen bytes, schema and fixtures are
untouched by every change above; the three forks carry their recommended defaults per Luke's instruction. v1 freezes
only on his word.*

---

## Appendix B — v2 audit trail (S1-68)

Every v2 change, mapped to the section of the design note (`research/facts-temporal-swap-design.md`, AST-146) that
justifies it. Nothing else changed: every section not listed here is byte-identical to frozen v1.

### B.1 Change → justification map

| # | v2 change | Where | Justified by (design note §) |
|---|---|---|---|
| B-1 | Title, status, revision, work-item, gate, home and supersedes rows now read DRAFT v2, NOT FROZEN; v1 named the governing contract | header | Header ("RFC v1 frozen"); §7 S1-68 row ("v1 stays frozen"); Luke's green-light (2026-10-07) |
| B-2 | `superseded_by` removed from the §7.4 field table | §7.4 | §3 Deletes: "`superseded_by` (field + the `:supersede` action), the create-then-supersede transaction, `current?`, the `:current` filter" |
| B-3 | `valid_at` (the record-validity period) added to the §7.4 field table | §7.4 | §3 wire-shape answer ("gains the period (`valid_at`) and `scope_hash`"); §2 two-axes correction (the period is *record* validity; `valid_until` stays the *domain* axis, an attribute) |
| B-4 | `scope_hash` added to the §7.4 field table | §7.4 | §2 identity row (`scope` is a map and can't key an exclusion constraint; a derived canonical-JSON digest, pure, replay-identical, `DeriveSubject` discipline; `WITHOUT OVERLAPS` on `(subject_type, subject_id, predicate, scope_hash)`); §7 AST-147 |
| B-5 | §7.4 implementation notes rewritten to the temporal mechanism (as-of-now reads derive membership; omission = period truncate at `effective_at`; revise = period split at `effective_at`; `WITHOUT OVERLAPS` identity; period index + exclusion constraint; materialiser stays sole writer) | §7.4 | §2 mapping table (all six rows) and "Who writes facts"; §1 n.4 verdict ("the partial-on-current index becomes the period index + the `WITHOUT OVERLAPS` exclusion constraint; plans stay part of acceptance") |
| B-6 | §7.4 contract-of-record re-pointed at the temporal fragment, with v1's named fragments kept as the frozen contract until freeze | §7.4 | §7 AST-147; §5 (0.2 parallel fragment, 0.3 cut-over, 1.0 removal) |
| B-7 | §7.4 normatives 1–6 carried verbatim; §7.2 (human entries win, omission supersedes, grade floors, the whole truth table) untouched | §7.4, §7.2 | §1 normative inventory — every normative "survives verbatim" (n.4 with the implementation-note change only); §1 final row (admission *policy* stays in the materialiser by design) |
| B-8 | Changelog v2 entry appended; DRAFT status carried consistently | §17, header | §3 ("this is a v2, plainly"); §1 closing ("what makes this a legitimate v2 rather than a v1 amendment") |

### B.2 Breaking-change declaration (per §11)

v1 §11 fixes the rule: **"removing or renaming a field" is breaking, requiring a major version bump.** This revision
removes the facts-table field `superseded_by` and adds `valid_at` and `scope_hash`. The §7.4 field shape — the
contract-of-record for derived facts — therefore changes non-additively, and **this revision is v2 by §11's own
rule; a v1 amendment would be illegitimate.** The break is confined to the derived facts table's contract-of-record:
the judgment records themselves (observations, bandings, admissions, verdicts, calibration runs, certifications) are
untouched. Until Luke's freeze word, **v1 remains the frozen contract of record**; this document is a DRAFT.

### B.3 Deliberately not changed

- **§7.2** — admission *policy*, not validity bookkeeping; it stays in the materialiser by design (note §2). The
  omission rule (§7.2 n.4) is carried verbatim and is realised mechanically by the period truncate.
- **§11** — its rule set is applied by B.2, not amended; byte-identical to v1.
- **§14, §15, Appendix A** — v1's historical freeze record and landing plan; byte-identical to v1.
- Every section not listed in B.1 — byte-identical to frozen v1 by construction (full copy, surgical edit).

*v2 freezes only on Luke's explicit word, as every revision before it. Until then: DRAFT — v1 governs.*
