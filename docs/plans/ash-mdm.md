# ash_mdm — Master Data Management for ash_enterprise (PRD + TRD)

## Context

Luke wants `ash_mdm`: per-enterprise-customer data ingress where each customer's schema is mapped onto our canonical model **without a deploy**, then matching/enrichment, human confirmation of low-confidence matches (System One machinery from the S1 Plane project), import/merge into golden records, egress back out, and data lineage throughout. Flagship UI flow: a CS person receives a list of new customer records → imports → system enriches and finds matches → human confirms low-confidence matches → import completes. Maximal reuse of the existing ash ecosystem; only glue code new.

This plan amends ADR 0017 (which forecloses stewardship UIs) and upgrades roadmap item `mdm` (P4, planned) to an active build.

## Research digest — what exists and what the plan reuses (all verified this session)

**Ingress substrate — `ash_discrete_business_events` (github lukegalea, NOT yet a dep; BIZEV-3 raw-landing and BIZEV-4 ledger shipped on current branch):**
- `SourceRecord`: temporal raw landing. Identity `(source, stream, external_id, region)` with period-aware `WITHOUT OVERLAPS` GiST constraint; idempotent `land` (identical content = temporal no-op, changed content splits period); zone/residency admission **at land** (refuses untagged / non-admitting tag, ADR 0042); cursor-as-data (`advance_cursor`/`reset_cursor` are period splits); as-of read `SourceRecord.at/5`.
- `Ledger`: dedicated `AshEvents.EventLog`; rows carry `event_kind`, subject as descriptors (never FKs), `occurred_at`/`observed_at`/commit-order `sequence` (per-region advisory xact lock), per-region SHA-256 hash chains (DB trigger + `mix bizev.verify_chains`), corrections as `supersedes_event_id`, delivery idempotency `delivery_key`, and `provenance: %{mapping_name, mapping_version_hash, source_record_id}`.
- Ships **resource macros, not concrete modules** (host policies govern natively) — the exact pattern ash_mdm must copy (ADR 0009 family convention).
- Requires ash `~> 3.34`, ash_postgres `~> 2.14` (temporal in tree), PostgreSQL 18 (family floor per S1-66 GO ALL IN ruling).

**Canonical model (host):** `lib/ash_enterprise/canonical/` — Person (`unique_email`), Account (`unique_provider_account`), Project/Task/Conversation/Message/CalendarEvent (`unique_external` pairs), all on `AshEnterprise.Platform.Resource` (`tenant?: true`), each with `upsert_from_source` + `by_external` actions; `Canonical.Projection.replay/2` deterministic raw→canonical projection (fixture-tested byte-identical replay).

**Entity resolution priors:**
- ADR 0017 (`docs/adr/0017-entity-resolution-in-ash.md`, status **proposed**, nothing built): in-Ash resolution over CDM-derived resources; blocking pushed into Postgres (`pg_trgm` + `fuzzystrmatch`, neither yet in `AshEnterprise.Repo.installed_extensions/0`); scoring = Ash calculation over candidate pairs; merge = ordinary action setting `merged: true` + `master_id` (CDM `Account`/`Contact` corpus shape — adopt, don't invent); candidate generation MUST run as system actor (review queue must not leak candidate existence to actors who can't read them); merge audited under ONE correlation id (merges revoke per-record grants — shares don't follow the survivor); Splink (MIT) = escape hatch for statistics. **Foreclosed by 0017: review queue, rule builder, lineage-of-merges UI** — amended by this plan (see TRD §1).
- roadmap.json `mdm` item: "Master data and entity resolution", P4, planned, choice "In-Ash resolution over CDM resources"; q21 asks "The same customer arrived from three systems — which one is real?"

**System One (S1 Plane project + `lib/ash_enterprise/system_one/`):**
- Judgment ledger (append-only, `record_hash`, person-no-write path), **Banding**: frozen bands `admit | review | omit`, band tables resolved through versioned DMN via `Banding.Step.band/2` — thresholds are DMN earned by calibration (ADR 0041), `:review` writes nothing (absence = unknown), `:banding_id` idempotency key.
- **ReviewQueue** (`system_one/review_queue.ex`): `ReviewQueue.pending/1` — four kinds today (`:question_proposal`, `:band_table_proposal`, `:review_band`, `:certification_revocation`); read-only data surface.
- **HumanVerdict** (`system_one/human_verdict.ex`): person-only create (`Checks.PersonActor` — no system/ai actor can forge a confirmation), reviewer as input, feeds live calibration (`CalibrationSampleWriter`). This IS the "human confirms" primitive.
- QuestionProposal/FilterProposal pattern (`policy-to-question.md`, S1-61): model proposes → person edits/approves → activates; version chains (`root_id`/`supersedes_id`), status enum `proposed|refused|approved|rejected|superseded`, raw output retained on refusal. Nothing auto-registers.
- Facts: temporal (`WITHOUT OVERLAPS`) materialised truth; three-valued (unknown-on-absence); `SystemOne.judge_context/1` threads tenant + correlation id into every judge action.

**Human tasks & UI:** `Bpmn.HumanTask` (claim model: `open→claimed→completed|cancelled`, no owner until claimed, `TaskCandidate` rows from `Process.AssignmentResolver` with maker-checker exclusions), `AshBpmn.Web.TaskListLive` (host LiveView is 13 lines supplying principal ids), audit-event subscriptions auto-start processes (`Bpmn.Subscription` + `Audit.EventSource`), A2UI declared surfaces (`AshA2ui.Standalone`, `FindingUI` = steward-drill-down precedent), dynamic surfaces with allowlists. Gap: no side-by-side diff component (build server-rendered, no JS).

**Lineage/audit:** platform base auto-attaches `AshOpenLineage.Extension` (table-level, leak rule: no actor/tenant/value facets); `Platform.Correlation` UUIDv4 — the OpenLineage runId == audit `metadata["correlation_id"]`; `Lineage.ingestion_event/4` for job-level start/complete/fail; `Audit.EventLog` per-tenant hash chains; import envelope precedent `ledger/user_ingestion.ex:80-94` (`ash_events_metadata` context merged by `StampCorrelation`).

**Rules/compliance:** ash_rules IR = fact triples + `has/neg/var` probes, five-value lattice, content-hashed serializable bundles; ash_compliance control plane = catalogs/profiles/waivers per tenant with fixed layering precedence; projector grain `[organization_id, control_id, subject_type, subject_id]` → Findings + append-only `ComplianceEvaluation`. Scout verdict: reusable as-is for MDM data-quality (facts like `["record","email_domain",…]`); gaps: compliance-flavored outcome vocabulary (reuse semantically: gap = stewardship task), no matching engine, no bulk evaluation.

**ash_strangler (patterns, not dependency):** mapping DSL vocabulary worth copying as *data* semantics — `key` uuid_v5 derivation, `decode` (total+injective value tables), `coalesce`/`concat`/`collapse`/`constant`/`unmapped because:`, total-attribute accounting (every target accounted for), compile-verifier suite (become runtime mapping validators), estate-from-mapping. Twins are NOT golden records (typed snapshots of source relations).

**External MDM market (web, 2026-10-13):** 4 styles (Registry/Consolidation/Coexistence/Centralized) — our case = consolidation with registry XREF: customer systems stay sources of truth; we own the golden record; coexistence write-back = later. Match-merge canon: blocking → scoring (deterministic/fuzzy/probabilistic/LLM-assisted) → **thresholds: auto-merge / steward review / no-match** → survivorship (source rank, recency, completeness, steward override) → golden record. Deploy-free onboarding is its own product category (Flatfile: AI mapping proposal + human confirm) — exactly the S1-61 pattern applied to schemas.

---

## PRD

### Problem
Every enterprise customer arrives with their own schema (CSV extracts, API payloads, Salesforce objects). Today ingress is deploy-bound: pipelines are compile-time config (`tap_worker.ex` config), the only mapper is hand-written code (`ledger/user_ingestion.ex`), SourceObject has no customer dimension and a known stream-collision identity gap, and there is no matching, stewardship, or egress at all. Onboarding a new customer schema requires an engineer and a release.

### Personas
1. **CS / onboarding specialist** — receives a customer's file/list; not a developer; must land it, map it, review matches, finish the import. Works entirely in the UI.
2. **Data steward** — owns match quality; confirms/rejects low-confidence matches; calibrates thresholds over time.
3. **Platform engineer** — declares canonical entities (deploy-time, rare), new *system adapters* (deploy-time, rare); everything per-customer must be data.
4. **Enterprise customer** — consumes egress in their own schema shape.

### Flagship user story (acceptance backbone)
As a CS person: I upload a customer's CSV of contact records I've never seen before → I create (or accept an AI-proposed) mapping from their columns to our Person/Account fields in the UI, with validation showing every field accounted for → I run the import → the system lands rows (zone-admitted), maps+enriches them, finds matches against existing golden records → high-confidence matches auto-merge, low-confidence ones land in my stewardship queue with a side-by-side view and scores → I confirm or reject each; my confirmations are recorded as human verdicts and feed calibration → merged/new golden records are visible with full lineage (which source rows, which mapping version, which human decided) → I export the resulting golden set back into the customer's schema shape. **No deploy happened.**

### Scope
- **In:** mappings as versioned data (ingress + egress), import batches, staging + validation, deterministic matching with rules-as-data, System One banding + human confirmation, BPMN-driven stewardship queue + UI, survivorship + merge/unmerge, SourceIdentity XREF registry, lineage end-to-end, per-tenant data-quality rule profiles.
- **Out (inline, at temptation points):** probabilistic/EM-trained linkage (Splink escape hatch stays; v1 = deterministic + fuzzy scores banded by DMN), coexistence write-back to customer systems (egress = export/pull only), new third-party system *adapters* (adapters are code = deploy; mappings are data = no deploy), bulk re-match UI tooling, CDM Contact/Account full adoption (flagship runs on existing canonical Person + Account; CDM generation is the production follow-through, unchanged `mix cdm.gen.resource` path).

### Success metrics
1. New customer schema onboarded with **zero code changes** — pinned by a test that authors everything through code interfaces/UI at runtime.
2. Steward confirmations recorded as calibration-feeding HumanVerdicts; band table improves from data, not releases.
3. "Which sources/humans/decisions produced this golden record?" answerable by one correlation-id query.
4. Replay determinism: golden projection rebuilt byte-identical (family contract).

---

## TRD

### 1. ADR 0050 — amending 0017 (do this first)

New `docs/adr/0050-mdm-stewardship-is-system-one.md` (declarative title convention), status accepted:
- **Keeps verbatim from 0017:** in-Ash resolution; golden record IS the platform resource with CDM `merged`/`master_id` shape; blocking in Postgres (`pg_trgm`, `fuzzystrmatch`); scoring as Ash calculation; candidate generation under system actor with separately-filtered presentation; merge audited under one correlation id; Splink escape hatch.
- **Amends the Foreclosed clause:** when 0017 was written (2026-08-18) a stewardship UI would have been a bespoke product. The substrate now exists as reusable first-party machinery: ReviewQueue, HumanVerdict (person-only), BPMN HumanTask/TaskCandidate/AssignmentResolver, A2UI surfaces, band tables earned by calibration. The review queue, rule builder (mappings-as-data), and lineage-of-merges views are therefore built ON those, never bespoke.
- Must include the `## Does it consume ActorContext?` section (ADR 0009+ requirement): restates 0017's two sharp edges (system-actor candidate generation + presentation filtering; merge revokes grants → correlation-id-audited) and adds: HumanVerdict refuses non-person actors; mapping activation is person-gated; egress honors zone admission taken at land (ADR 0042) with cross-region export refused absent an admitting zone policy.
- Roadmap: `docs/roadmap.json` — `mdm` item gets `status: "in-progress"`, `adr: "0050"`; keep priority (it says P4; note in effort text that ingress/lineage prerequisites have since shipped). Run `mix ash_enterprise.roadmap --check` (devenv).

### 2. Package + host split (ADR 0009 playbook)

- **New public package `ash_mdm`** (github lukegalea/ash_mdm, MIT, REUSE.toml, CI mirroring ash_discrete_business_events): generic MDM machinery as **resource macros + Spark DSL**, depending on `ash ~> 3.34`, `ash_postgres ~> 2.14`. It never depends on ash_enterprise.
- **Host domain `AshEnterprise.Mdm`** (`lib/ash_enterprise/mdm.ex` + `lib/ash_enterprise/mdm/`): instantiates package resources on `AshEnterprise.Platform.Resource` (bizev macro pattern — host policies govern natively), owns orchestration glue, seeds, judgment questions, band tables, BPMN definition, UI.
- Host `mix.exs` deps += `{:ash_discrete_business_events, github: "lukegalea/ash_discrete_business_events"}` (pinned by mix.lock; BIZEV-3/4 capabilities only) and `{:ash_mdm, github: "lukegalea/ash_mdm"}`.

### 3. Data model

Package macros (`use AshMdm.Resources, :<name>`), host instantiates each on Platform.Resource with `tenant?: true, ownership: :organization_owned, audit?: true` (stewardship decisions are audited; mapping rows are configuration, `audit?: true` too — who changed a mapping matters):

1. **`Mapping`** (table `mdm_mappings`) — one row per (tenant, direction, source, stream, target entity) *version*.
   - Attributes: `direction :atom one_of [:ingress, :egress]`; `source :string(64)` (system name, e.g. `"manual_csv"`, `"salesforce"`); `stream :string(64)`; `target_resource :string` (module name, resolved against a host allowlist); `field_rules :map` (ordered list of rules, shape below); `observed_schema :map` (inferred source schema: field → type/observed values, captured at proposal time); `status :atom one_of [:draft, :validated, :active, :retired]`; `version :integer`; `root_id`, `supersedes_id` (version chain — FilterProposal pattern, nothing overwritten); `content_hash` (SHA-256 over canonical field_rules JSON); `activation_note`.
   - Identity: `:one_active` unique `(organization_id, direction, source, stream, target_resource)` **where `status = 'active'`** (partial unique index).
   - Actions: `:draft` (create), `:validate` (runs the validator set below; transitions draft→validated or returns per-field errors), `:activate` (person-gated policy `Checks.PersonActor`; supersedes predecessor → predecessor `retired`), `:retire`, `:propose` (system-actor AI proposal, MDM-8), `:create_version` (person edit, revalidates).
   - **Field rule shape (data, closed vocabulary):** `{"path" => "Email Address" | "raw_payload.Contacts[].Email" (dot-path into raw payload or CSV column), "target" => "email", "op" => <operator>, "args" => %{...}, "required" => true|false, "read_only" => false, "because" => "human note"}`. `unmapped` targets carry `because:` (ash_strangler discipline: total accounting, an unexplained unmapped attribute is a validation error).
   - **Operator vocabulary (closed, exact):** `identity` (no-op passthrough), `cast` (target Ash type), `trim`, `case` (`down|up`), `parse_date` (ISO8601 + common enterprise formats), `parse_decimal`, `decode` (value table map, must be total+injective — validator rejects otherwise, with counterexample), `concat`, `coalesce` (ordered fallback paths), `constant`, `regex_extract`, `ref_lookup` (host Reference domain: currency/locale/timezone codes), `uuid_v5` (namespace + args — ash_strangler KeyDerivation semantics for cross-system keys). Unknown op = validation error. No eval, no quoted Elixir — the evaluator is a pure fold (`AshMdm.Mapping.Evaluator.run/2`).
   - **Runtime validation set** (activate gate; mirrors ash_strangler verifiers as data checks): every target attribute of `target_resource` accounted for (mapped / constant / explicitly-unmapped-with-because) via `Ash.Resource.Info.attributes/1` introspection; type compatibility path→op→target constraint; decode totality+injectivity; required-path presence in `observed_schema`; `read_only` targets refused when `direction: :egress` input implies write-back. Validation results stored as `validation_findings :map` on the row.
2. **`ImportBatch`** (table `mdm_import_batches`) — `status :atom one_of [:open, :staging, :matching, :review, :closed, :failed]`; `mapping_id` + `mapping_content_hash` (pinned at open — a batch never re-maps mid-flight); `counts :map` (`landed, staged, validation_failed, candidates, admitted, review, omitted, created, merged`); `correlation_id` (the lineage run id, `Platform.Correlation.id()` at open); `region` + `residency_tag` (zone discipline); `source_ref :map`. Actions: `:open`, `:stage` (map all landed-but-unstaged SourceRecords for the batch's stream → StagedRecords), `:run_match`, `:close`, `:fail`. Oban worker `AshEnterprise.Mdm.BatchWorker` drives the pipeline (queue `:mdm`), wrapping everything in `Platform.Correlation.with_correlation/2` + `Lineage.ingestion_event(:start/:complete/:fail, "mdm", "batch:<id>", run_id: batch.correlation_id, inputs: [source refs], outputs: [canonical tables])`.
3. **`StagedRecord`** (table `mdm_staged_records`) — `batch_id`; `source_record_id` (bizev SourceRecord ref); `mapped :map` (canonical-shaped key/values); `validation_findings :map`; `status :atom one_of [:staged, :matched, :admitted, :review, :omitted, :created, :merged, :rejected]`. Identity `:one_per_source_record (batch_id, source_record_id)`.
4. **`MatchCandidate`** (table `mdm_match_candidates`) — `staged_record_id`; `golden_resource :string`; `golden_id :uuid`; `score :decimal`; `explanation :map` (per-rule contributions: `{"email_exact" => 1.0, "name_trigram" => 0.82}`); `band :atom one_of [:admit, :review, :omit]` (resolved via band table, never hardcoded); `status :atom one_of [:pending, :auto_merged, :confirmed, :rejected, :superseded]`; `human_verdict_ref :map` (envelope-class: judgment ledger observation ids + digests — HumanVerdict rows live in System One, not here). Identity `:one_pair (staged_record_id, golden_resource, golden_id)`.
5. **`SourceIdentity`** (table `mdm_source_identities`) — the XREF registry: `source :string`, `stream :string`, `external_id :string`, `golden_resource :string`, `golden_id :uuid`, `asserted_by :atom one_of [:mapping, :steward]`, `confidence :decimal`. **Temporal** (ash_postgres periods, same shape as bizev SourceRecord): period-aware identity `WITHOUT OVERLAPS` on `(organization_id, source, stream, external_id)` — a source id points to exactly one golden at a time; re-merge closes the old period and opens a new one (ADR 0049: temporal resources are the validity substrate).

6. **`MatchRuleSet`** (table `mdm_match_rule_sets`) — specified in §5 (per-tenant match rules + survivorship policy, versioned + person-gated like Mapping). Listed here so §3 is the complete resource inventory.

Host additions to canonical entities (migration; ADR 0017/CDM shape): `Canonical.Person` and `Canonical.Account` gain `merged :boolean default false` + `master_id :uuid` (self-ref) + action `:mdm_merge_into` driven by package change `AshMdm.Changes.MergeInto` and `:mdm_unmerge` (correction). Unmerge restores loser (`merged: false`, `master_id: nil`), closes SourceIdentity periods, and — when a bizev ledger is configured — records `event_kind: :"mdm.record_unmerged"` as a correction row (`supersedes_event_id` of the merge event).

### 4. Landing (bizev integration, no new landing code)

CS upload (`/app/mdm/import` LiveView, §9) lands rows via `SourceRecord.land/1` with `source: "manual_csv"` (or the customer's system name), `stream: <customer+dataset slug>`, `external_id: uuid_v5(row key)` or the customer's row id, `region`/`residency_tag` from the tenant's zone — zone admission is inherited from bizev's land path for free. Streamed/API sources already flowing through bizev need only new Mapping rows. `ImportBatch.stage` reads via SourceRecord as-of reads; re-running a batch is a no-op on identical content (bizev temporal idempotency).

**Contingency (pre-decided):** if bizev proves unstable at integration time, host adapter `AshEnterprise.Mdm.Landing` (behaviour) falls back to the existing `Ingestion.SourceObject` with two prerequisite fixes — add `stream` to the `unique_source_object` identity and an `organization_id` column (the E1 known gap at `source_object.ex:75-82`). The adapter seam means no ash_mdm package change. Do not build this unless forced.

### 5. Matching engine (ADR 0017 mechanics)

- **Blocking** (`AshMdm.Match.Blocker`, system actor via `ActorContext.system/1`): exact keys (normalized email; `uuid_v5(name + tenant namespace)`) + `pg_trgm` similarity shortlist on name via expression index. Prerequisite: `AshEnterprise.Repo.installed_extensions/0` += `pg_trgm`, `fuzzystrmatch` + migration (ADR 0017's stated one-liner).
- **Match rule sets as data:** per (tenant, golden_resource) — `mdm_match_rules :map` on… a `MatchRuleSet` package resource (`mdm_match_rule_sets`, versioned like Mapping but simpler: `rules` = `[%{kind: :exact, fields: [...]}, %{kind: :fuzzy, field: :name, algorithm: :trigram|levenshtein, weight: w}]`, no thresholds — thresholds live in band tables). Stored as data; activating a rule-set version is person-gated.
- **Scoring** (`AshMdm.Match.Score`, expression calculation pushed to SQL where comparators are SQL functions, BEAM fallback — ADR 0017 verbatim): weighted sum → `score` + `explanation` per candidate.
- **Presentation filtering (0017's leak rule):** StewardLive and ReviewQueue surfaces intersect candidate `golden_id`s with the viewer's readable set (`ActorContext`); the count shown is the filtered count, never the raw candidate count. Candidate generation itself is unaffected (system actor).

### 6. Banding + stewardship (System One, the heart of the flow)

- **Judgment question** (host DSL on `StagedRecord`, wording pinned in `priv/judgments/lock.json` like the existing five): `question :mdm_matches_candidate, answer_type: Choice[yes, no, unsure]` — used only when deterministic score lands in the gray zone and an LLM compare is warranted (inputs: staged snapshot + golden snapshot; every answer = ledger observation via `SystemOne.judge_context/1`).
- **Band table:** DMN decision `mdm_match_bands` in `AshEnterprise.Decisions` (host), inputs `score`, `entity`, `tenant`; outputs band `admit|review|omit`. Seeded conservative (wide `review`) — bands tighten only through `CalibrationRun → proposed_table → BandTableCertification → activation` (S1-62 quick approval loop; ADR 0041: thresholds are DMN, earned by calibration). Both the deterministic score and any judgment answer route through `Banding.Step.band/2` with `:banding_id` = candidate id (idempotent).
- **Routing:** `admit` → auto-merge (survivorship, §7); `review` → ReviewQueue item **+ BPMN HumanTask**; `omit` → staged record proceeds as new-golden candidate or rejected per required-field findings.
- **ReviewQueue:** host extends `SystemOne.ReviewQueue` with kind `:mdm_match` (pending MatchCandidates `band: :review, status: :pending`, oldest-first, paginated — same shape as existing kinds).
- **BPMN:** `priv/bpmn/mdm_stewardship.bpmn` (package-shipped template, host-registered): HumanTask per review candidate, AssignmentResolver clause `role: :data_steward` (new `Security.Role` seed) + maker-checker exclusion (the importer isn't the confirmer when they're also a steward). Task completion requires the HumanVerdict first (task form calls the verdict action) — the claim/SLA machinery is BPMN's, the decision record is System One's.
- **HumanVerdict:** confirm (`yes`) → merge; reject (`no`) → candidate rejected + staged record proceeds; `unsure` → escalate to steward lead (re-assignment). Every verdict feeds `CalibrationSampleWriter` — stewardship improves the bands.

### 7. Survivorship + merge

- **Survivorship policy as data:** per (tenant, golden_resource) on `MatchRuleSet`: `survivorship` = per-attribute strategy `most_recent | source_rank | most_complete | steward_override | non_null` + ordered `source_rank` list (e.g. `["salesforce", "manual_csv"]`). Evaluated by pure fold `AshMdm.Survivorship.resolve/2` producing the merged attribute set + per-attribute provenance (which source row won which field).
- **Merge action** (`AshMdm.Changes.MergeInto` on canonical `:mdm_merge_into`): one transaction — survivor attributes per survivorship policy; loser `merged: true, master_id: survivor.id`; SourceIdentity: loser's identities close periods, re-point to survivor (new period, `asserted_by` preserved); MatchCandidate → `auto_merged|confirmed`; ledger event `:"mdm.record_merged"` (when ledger configured) with provenance `{mapping_name, mapping_version_hash, source_record_ids}`; **whole merge under the batch's correlation id** (0017's grant-revocation audit requirement — "why did this disappear" stays answerable).
- **Unmerge:** loser restored, periods closed, ledger correction row superseding the merge event. Non-destructive by construction (losers survive per CDM shape).
- **Golden projection determinism:** `AshEnterprise.Mdm.Projection.replay/1` (mirrors `Canonical.Projection.replay` contract): rebuild golden state from SourceRecords + active Mappings + SourceIdentities + recorded decisions; byte-identical replay pinned by fixture test. (Deterministic scores only — LLM compares are recorded observations, replayed as ledger reads, never re-asked.)

### 8. Egress

- `Mapping.direction: :egress` (target = the *customer's* schema, `observed_schema` = their declared shape; field rules map golden attributes → customer fields; `ref_lookup`/`decode` invert where the tables are injective).
- Export action `AshEnterprise.Mdm.export!/2` (code interface): builds customer-shaped rows from golden records (+ SourceIdentity list per row when the customer wants cross-refs); streams as CSV/JSON download. Cross-region export refused unless the tenant's zone policy admits (Zones jurisdiction check at the export action — ADR 0042 keeps admission at land; this is the disclosure gate, mirroring bizev's `cross_region_read` discipline).
- Streaming outbound events (write-back) = existing roadmap `outbound events` item, not ash_mdm; ledger consumers can already tail `feed/2` for golden-change events (`:"mdm.record_merged"` etc.) — that's the coexistence seam, one line in docs.

### 9. UI (all server-rendered, no new JS)

1. **`AshEnterpriseWeb.Mdm.ImportLive`** (`/app/mdm/import`, `lib/ash_enterprise_web/live/mdm/import_live.ex`): upload CSV → preview (first N rows + inferred `observed_schema`) → mapping step: pick existing mapping version or draft new (AI proposal button when MDM-8 lands); field-rule editor (`<.input>` grid: source path → target select from manifest → op select from closed vocabulary → required/read_only) with live `:validate` results per field → open batch → live progress (counts by status via PubSub row-change broadcasts, existing pattern) → link to steward queue.
2. **`AshEnterpriseWeb.Mdm.StewardLive`** (`/app/mdm`, `lib/ash_enterprise_web/live/mdm/steward_live.ex`): stream of review-banded candidates (LiveView streams, `phx-update="stream"`), oldest-first; per candidate a **server-rendered side-by-side diff** (attribute rows: staged value vs golden value, winner-per-survivorship highlighted, per-field score contributions) + band + explanation; actions: confirm / reject / create-new-golden / unsure-escalate; writes HumanVerdict + drives merge/create; also surfaces these as BPMN tasks (TaskListLive claim view works unchanged). Empty-state and count via separate assigns (streams don't count).
3. **A2UI declared surfaces** (`lib/ash_enterprise_web/a2ui/`): `mdm_mapping_ui.ex` (mapping version chain drill-down), `mdm_golden_ui.ex` (golden record + SourceIdentity rows + merge lineage: correlation-id query of audit events, rendered as the surface's rows) — `FindingUI` is the precedent to copy.
4. Router: `/app/mdm` scope, `live_session` with `current_scope` per repo Phoenix v1.8 rules; `on_mount(:assign_tenant…)` like `Bpmn.Helpers`.

### 10. Compliance integration (quality rules ride ash_rules/ash_compliance)

Host rule set `AshEnterprise.Mdm.QualityRules` (`use AshRules`; facts: `[:mdm_email_present, :mdm_source_count, :mdm_last_verified_days, …]` over staged/golden records as triples), catalog `mdm-quality`, per-tenant profiles (e.g. enterprise customer requires verified email), projector `AshEnterprise.Mdm.QualityProjector` (`use AshCompliance.Projector, name: "mdm_quality_findings_v1"`, grain `[organization_id, control_id, subject_type, subject_id]`). Findings with gaps → stewardship: the existing BPMN audit-event subscription starts a stewardship task per finding (same subscription machinery as KYC). Waivers = `PolicyOverride` per tenant, unchanged.

### 11. Lineage end-to-end (the contract)

One import = one correlation id, set at `ImportBatch.open`, threaded by `Platform.Correlation.with_correlation/2` through stage/match/band/merge/export. Answering "where did this golden record come from": SourceIdentity (which sources/external ids) → MatchCandidate + HumanVerdict refs (which decisions + which humans) → `audit_events.metadata->>'correlation_id'` (every write) → ledger `provenance` (which mapping version + source records) → OpenLineage run (same id) for the graph view. All five are existing query surfaces; ash_mdm only stamps ids consistently. Job-level runs via `Lineage.ingestion_event/4`; per-write taps come free from the platform base.

### 12. No-deploy guarantee analysis

New customer on existing system type (CSV/manual, any already-integrated API) = data only: SourceRecord stream + Mapping rows + MatchRuleSet profile + band table seeds → all runtime-gated resources. Deploy required only for: a new third-party *adapter* (code), a new canonical *entity* (migration), a new judgment *question wording* (lock.json is compile-pinned by design — questions are contracts, not config). This boundary is stated in ADR 0050.

---

## Slices (build order; each leaves the suite green)

| Slice | Delivers | Verification |
|---|---|---|
| **MDM-0** | ADR 0050 (accepted); `docs/plans/ash-mdm.md` (this plan, landed); roadmap.json `mdm` → in-progress/ADR 0050; `ash_mdm` package skeleton (ADR 0009 playbook: MIT, REUSE, CI, `.formatter.exs`, empty `AshMdm` module); host deps wired (`ash_discrete_business_events`, `ash_mdm`); `Repo.installed_extensions` += pg_trgm/fuzzystrmatch + migration | `mix ash_enterprise.roadmap --check` passes; `mix deps.compile ash_mdm ash_discrete_business_events`; extensions present in `select extname from pg_extension` after migrate |
| **MDM-1** | `Mapping` resource + operator vocabulary evaluator + runtime validator set + version-chain lifecycle (package); host `AshEnterprise.Mdm.Mapping` instantiation | Package tests: evaluator fold over fixture field_rules; validator rejects incomplete accounting (unmapped without `because`), non-injective decode (counterexample asserted), unknown op; activation supersedes; partial-unique-index prevents two active |
| **MDM-2** | bizev landing adapter + `ImportBatch` + `StagedRecord` + `BatchWorker` + `Lineage.ingestion_event` wrapper + zone-admitted land (host) | Feature test: land CSV fixture rows as SourceRecords (tagged region), open batch, stage → StagedRecords with mapped maps + validation findings; re-run batch = no-op; audit rows carry batch correlation id; OpenLineage start/complete emitted (transport no-op safe) |
| **MDM-3** | `MatchRuleSet` + blocking (exact + trigram) + `MatchCandidate` + score/explanation calculation (package + host wiring on Person) | Test: seeded golden Persons; batch with 2 exact dupes, 1 fuzzy dupe, 1 new → candidates with expected scores/explanations; blocking runs as system actor (assert actor in audit); quadratic guard: trigram shortlist query plan uses GIN index (`EXPLAIN` assertion) |
| **MDM-4** | Band table `mdm_match_bands` (seeded wide-review) + judgment question + ReviewQueue `:mdm_match` + BPMN stewardship process + StewardLive queue/diff/confirm UI | Test: admit-band auto-merges, review-band creates queue item + human task; StewardLive live-test: confirm writes person-only HumanVerdict (system actor refused — negative test per repo convention), merges, task completes; leak rule: steward without read on a golden sees it filtered out of the queue, count excludes it |
| **MDM-5** | Survivorship resolve + `MergeInto`/unmerge + `SourceIdentity` temporal XREF + `Mdm.Projection.replay` + ledger merge/unmerge events; `merged`/`master_id` on Person/Account | Test: merge picks per-attribute winners per policy, one correlation id across survivor+loser audit rows; unmerge restores; XREF period math (`WITHOUT OVERLAPS` refusal on overlap); replay byte-identical |
| **MDM-6** | Egress Mapping direction + `export!/2` + zone disclosure gate + golden A2UI surface (`mdm_golden_ui`) + `mdm_mapping_ui` | Test: export produces customer-shaped rows from goldens; cross-region export refused without admitting zone policy (negative test); A2UI surfaces render (surface fixture pattern) |
| **MDM-7** | QualityRules + `mdm-quality` catalog/profiles + QualityProjector + findings→stewardship BPMN wiring | Test: tenant with "verified email" profile imports records missing email → finding created → stewardship task started via existing subscription; waiver suppresses after `PolicyOverride` |
| **MDM-8** | AI mapping proposals: `Mapping.propose` (semantic manifest of target + observed schema + samples → field-rule proposal, raw output retained), person edit/approve → activates (S1-61 pattern) | Test: proposal against unseen CSV fixture produces valid field rules for ≥ the deterministic columns (email/name mapping proposed); refusal path retains raw output; nothing activates without person actor (negative test) |

Dependencies: MDM-1→2→3→4→5→6 strictly ordered; MDM-7 after 4 (needs stewardship), MDM-8 after 1 (needs Mapping), otherwise independent.

## Critical files & anchors

- `docs/adr/0017-entity-resolution-in-ash.md` — constraints kept verbatim (system actor, correlation-audited merge, PG blocking); amend via new 0050.
- `lib/ash_enterprise/system_one/review_queue.ex`, `system_one/human_verdict.ex`, `system_one/banding/step.ex` — the confirm-low-confidence primitives ash_mdm routes through (kind `:mdm_match` added to ReviewQueue).
- `lib/ash_enterprise/ingestion/source_object.ex:75-82` — E1 identity gap; only touched under the bizev contingency.
- `lib/ash_enterprise/ledger/user_ingestion.ex:80-94` — provenance envelope precedent (`ash_events_metadata` + StampCorrelation).
- `lib/ash_enterprise_web/live/bpmn/task_list_live.ex` + `lib/ash_enterprise_web/a2ui/finding_ui.ex` — the two UI patterns (13-line task list; A2UI drill-down) the steward surfaces copy.

## Verification (end-to-end proof, after MDM-6; the acceptance backbone)

All commands inside the devenv environment (never bare `mix` per HANDOFF):

1. `mix test test/ash_enterprise/mdm/cs_import_flow_test.exs` — the flagship story as one feature test: seeded tenant + goldens; upload unseen-schema CSV fixture (`test/fixtures/mdm/acme_contacts.csv`); **author the mapping via the code interface at runtime** (assert no recompilation happened: capture `:code.which/1` before/after); run batch; assert counts (created/admitted/review), one auto-merge under a single correlation id, SourceIdentity rows, HumanVerdict after steward confirm, export rows in the customer's shape.
2. `mix test test/ash_enterprise/mdm/lineage_test.exs` — for a merged golden: query by correlation id → audit chain (survivor + loser), ledger provenance (mapping hash + source records), SourceIdentity sources, verdict refs; OpenLineage run id equals correlation id.
3. UI: `mix test test/ash_enterprise_web/mdm/steward_live_test.exs` (element-ID based assertions per repo test rules) + one manual pass: `devenv shell -c "mix phx.server"` → `/app/mdm/import` upload → `/app/mdm` review → confirm → `/app/mdm` golden surface shows lineage (screenshot into `scripts/screenshots/`).
4. Determinism: `mix test test/ash_enterprise/mdm/projection_replay_test.exs` — delete goldens, `Mdm.Projection.replay`, byte-identical.
5. Full suite + gates: `mix precommit`, `mix ash_enterprise.roadmap --check`, `EXTRA_DOCS=1 mix docs --warnings-as-errors`.

## Assumptions & contingencies

1. **Package shape** (user-overridable): `ash_mdm` is a separate public package per ADR 0009 + thin host domain, not host-only code. Family precedent (ash_judgments/ash_evidence/bizev) and cross-host reusability decide it.
2. **bizev dependency**: ash_mdm consumes only shipped BIZEV-3/4 surface (SourceRecord land/at, optional ledger events). If bizev's branch regresses, use the pre-decided `Landing` behaviour fallback over `Ingestion.SourceObject` (with the two E1-gap fixes); no package redesign.
3. **Flagship entity**: existing `Canonical.Person` + `Canonical.Account` (they exist, are exercised by `Projection.replay`, and ADR 0050 notes CDM Contact/Account generation as the production follow-through via the existing, unchanged `mix cdm.gen.resource` path).
4. **Splink stays the escape hatch** (ADR 0017): if deterministic+fuzzy+LLM-compare scores prove insufficient at scale, the scoring calculation is replaced by a read of a `match_candidate` table written offline — blocking/merge/stewardship untouched.
5. **LLM compare is optional per tenant** (cost + jurisdiction): default banding routes on deterministic score alone; the judgment question activates only for gray-zone candidates when a judge instrument is configured.
6. **Thresholds are never literals in code** — only DMN band-table outputs, seeded conservative, tightened via calibration (ADR 0041). If calibration data is thin at launch, the wide-review seed stands (more human confirmations, fewer wrong merges — the safe direction).
