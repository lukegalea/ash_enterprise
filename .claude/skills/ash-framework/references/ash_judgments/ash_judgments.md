# Rules for working with AshJudgments

AshJudgments is the System One judgment substrate: declared, typed, calibrated questions
over any Ash resource; answers recorded as observations with full provenance; recorded
judgments turned into DMN inputs, rule facts, process signals and evidence artifacts by
the bridges. Transport is upstream `ash_ai`'s evaluate action over ReqLLM — this package
ships no HTTP client or provider behaviour. Besides upstream's `AshAi.Evaluate.Noul`,
`Choice`, `Score` and the multi-field `Judgments` container, it ships two answer types of its own on the same path:
`AshJudgments.Evaluate.Extraction` and `AshJudgments.Evaluate.Evidence`. Read these rules
before using it; they are the package's contract.

## The four laws (stated for package users)

These are the first four rules because everything else follows from them. They are laws,
not preferences: code that breaks one is wrong even if it passes its tests.

### 1. Observe → admit → decide

Instruments propose observations; Ash actions admit them as facts; rules evaluate facts.
No model writes authoritative state. Models get read-only tools; `accept_*`,
`override_*` and `authorize_*` actions are never exposed to a model. A decoded,
constrained generative output is an observation too — never a fact until an authorized
action admits it.

- A judgment is a ledger row, not a permission. If your code lets a model answer change
  authoritative state directly, it is wrong — route it through the host's admit action,
  held by an actor with a grant (a named system actor for auto-admission, a human for the
  middle band).

### 2. Record, don't recompute

A model answer is an observation with a timestamp and instrument version. Replay and
projection rebuilds consume recorded observations and never re-run inference; re-inference
is a *new* observation.

- Ledger create actions **accept the answer as input**. Never call a model inside
  `change/3`: during `AshEvents` replay, changes still run, and a model call there would
  silently rewrite history.
- The cache/replay modes read the ledger. `:replay` answers only from recorded rows and
  errors on a miss — a replayed answer that disagrees with the original is worse than no
  answer.

### 3. Never in a check, never a grant

No model call inside a policy check, an `ActorContext` build, a FEEL expression, an
`ash_rules` evaluation, a projector, or a calculation. A model may inform authorization
only through a materialised, versioned, appealable fact admitted by an authorized action.

- `AshJudgments.Bridge.Rules` reads the ledger and emits facts; the guard path is
  synchronous ledger reads. If you find yourself calling an instrument from
  `Ash.Policy.Check`, stop.
- Pruning a tool list with `Ash.can?` is UX, never a security boundary.

### 4. Advisory in tooling

In developer and agent tooling, System 1 adds a separate, labelled signal. Deterministic
reports stay byte-identical and deterministic gates stay deterministic unless an explicit,
versioned promotion threshold says otherwise. Where a declaration can decide, a model
must not.

- Every surface states which rung answered (`rung: :system_one` in telemetry metadata) —
  keep that honest in anything you build on the package.

## The never list

- **Never call a model inside checks, FEEL, rules or projectors** — see law 3.
- **Never hold thresholds in config.** Bands are versioned DMN band tables, earned by
  calibration, per family (and per tenant severity tier where needed). A threshold in
  `config.exs` is unauditable policy.
- **Never store policy in this package.** It records observations and proposes band
  tables; it does not decide what is allowed.
- **Never apply a learned artifact in serving.** Proposals carry lineage; adoption is an
  approval; a revision re-earns calibration on data it never saw.

## Profiles, pinning and residency

- A floating tag (`-latest`, `-preview`) is a silent policy change and is forbidden in
  compliance paths. Pinned profiles carry a model digest; a `pin: :required` profile
  resolving to a floating alias raises, and one without a digest fails to resolve —
  a profile that cannot report a digest cannot feed admission.
- Every profile carries its residency (`in_cluster` | `sub_processor`). Host code
  implements the residency policy; a `sub_processor` call is a disclosure — one ledger
  row and one span, with `ai.disclosure=true` — and a tenant opt-out is honoured next to
  the client, not in a dashboard afterwards. The default posture denies sub-processor
  access for tenants with no recorded setting; unknown tenants never opt in by silence.
- `base_url` and `api_key` resolve from the environment at call time; never commit a
  literal key or endpoint to config or source.
- Profiles are swappable data, never code. The homelab models are prototype
  instruments — models are re-chosen at launch — so no model id, endpoint or key
  literal belongs in source. Hosts that route models across hosts do it with a config
  map (`:model_routes`), whose missing entries fail loud rather than silently falling
  back.

## Optional integrations

The bridges ride behind optional dependencies (`ash_decisions`, `ash_rules`, `ash_bpmn`,
`ash_compliance`, `ash_events`, `opentelemetry_ash`, and `ash_a2ui` for the surfaces). A
missing dep is a structured error, never a crash:

- `AshJudgments.Bridge.Rules.available?/0` returns `:ok` or
  `{:error, {:missing_dependency, :ash_rules}}`.
- `AshJudgments.Availability.report/0` lists every integration with its status, the dep
  to add, and what it unlocks.
- Gate new integration code behind `Code.ensure_loaded?/1` (the Ecto-Jason pattern) so
  the package keeps compiling with or without any of them.

## The DMN bridge and bandings

- Band tables live in `ash_decisions` (ADR 0041); the bridge only
  FLATTENS recorded answers into FEEL inputs (`Bridge.Dmn.inputs/2`) —
  decimal strings, present markers, never absent keys — and the
  evaluation goes through the host resolver seam. Nothing evaluates in
  this package, and nothing calls a model on the banding path.
- `matched_rule_ids` empty is a REFUSAL, not a result (ADR 0041): the
  host's banding step refuses before writing, and the fragment keeps
  the contract on the record.
- Bandings and certifications are recorded, never recomputed: their
  creates accept the band-table's outputs and the evaluation id as
  inputs (law 2). Bandings are immutable; facts are revised by the
  materialiser; certs are revoked. The frozen band enum is
  `admit | review | omit` — never `unknown` (that is the ash_rules
  outcome layer).
- Exploratory observations are never banded: `Bridge.Dmn.inputs/2`
  raises `ArgumentError` on one.

## The facts fragments

- New hosts define their facts resource on `AshJudgments.Facts.TemporalFragment`.
  `AshJudgments.Facts.Fragment` is deprecated since 0.3.0 and frozen; removal at 1.0.
- On the temporal fragment validity is a period (`valid_at`): a revision splits the
  period at the admission's `effective_at`, an omission truncates it, and a plain read
  is the as-of-now read. There is no `superseded_by`, no `:supersede` action and no
  `current?` — do not reach for them.
- `valid_until` is domain validity (an expiry date), not record validity: an expired
  fact still has a row and reads `expired`, never "no row".
- Uniqueness is `WITHOUT OVERLAPS` on `(subject_type, subject_id, predicate,
  scope_hash)`, which needs PostgreSQL 18 and the `btree_gist` extension in the host
  repo's `installed_extensions`.
- Let the migration generator create the facts table: it emits the temporal primary
  key, `PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)`. A table created by hand can lack
  it, and the generator cannot add it later on its own; repair it with the
  `AshJudgments.Facts.TemporalPrimaryKey` custom statement, not a hand-written
  migration.
- `AshJudgments.Facts.Materialiser` is the sole writer of facts. Human verdicts win,
  an omission writes no fact, and exploratory observations are refused
  (`ExploratoryRefused`).
- The evidence assertion is opt-in: a decision carrying `evidence_observation_id` (or a
  preloaded `evidence_observation`) is checked before the transaction against the
  observation's recorded input hash; a mismatch raises
  `AshJudgments.Facts.Errors.EvidenceMismatch` and writes nothing. Without the reference
  the path is unchanged.
- To move a legacy table to the temporal fragment, replay the recorded admissions
  through the materialiser in `effective_at` order; never translate the rows in SQL
  (README, "Replay your admissions").

## The ash_rules bridge

- The bridge reads the MATERIALISED FACTS TABLE, not the ledger: facts
  carry admission provenance, grade floors, freshness and scope; the
  ledger is the observation record reached via `admission_id`.
- Every fact-schema entry the bridge declares carries `missing:
  :unknown` — escalate means omission, an absent fact is unknown, never
  false.
- Fact values are SCALAR JSON first (`true`, `"urgent"`, `80`); wrapper
  maps only for genuinely composite values. The snapshot hash
  (`Bridge.Rules.snapshot_hash/3`) pins consumed inputs including
  explicit omission markers — probabilities never enter it.

## The explore tier

- Exploration never decides membership. Ordering by observation (`Exploration.Ordering`)
  reorders a candidate set the caller already holds and never filters it; anything that
  acts over a set reads admitted facts, never an ordering.
- An ordering names a declared question and one of its options (`selector`); a
  score-only ordering is refused (`ScoreOnlyOrdering`).
- An exploratory question (`Exploration.Run.run/4`) is an explicit, bounded action —
  never a trigger, background job or read path. Over `Exploration.hard_cap/0` (500)
  subjects is refused (`BoundExceeded`), never truncated.
- Exploratory rows carry `family: nil` and are never banded, admitted or fed to facts.
  Recurrence detection only proposes a question (`Exploration.Recurrence.promote/5`);
  a person declares it in the DSL.

## Agent-run lineage

- The ledger carries optional `run_id`, `step_id`, `tool_call_id`, `invocation_id` and
  `release_manifest` (strings, nil by default). The judge records them from the judge
  context's `judgments` map under those keys. They are envelope class and enter `record_hash`
  only when non-nil, so a row without lineage hashes exactly as before.
- Adding them to a host's ledger table is a nullable-columns migration; generate it with
  `mix ash.codegen`.

## Calibration

- `Calibration.propose_band_table/3` proposes; it never certifies or publishes. Below
  the family's `min_n` there is no table, and a refused proposal is still a recorded
  run (`result: :no_table`). A person certifies through
  `Banding.CertificationFragment`; publication is `ash_decisions`' lifecycle.
- An earned table has two ranges (admit at or above λ̂, review below), or three when the
  run also earned a lower threshold (`RiskControl.threshold_low/2`) and the family sets
  `low_band` in `FamilyConfig`: `:admit_no` admits a confident no with `fact_value`
  `false`, `:omit` drops it. Pass `low_band: FamilyConfig.low_band(family)` to
  `ProposalDmn.render/2` wherever you render a proposal. A lower threshold at or above the
  upper one is refused (`:thresholds_overlap`), never rendered.
- `mix ash_judgments.calibrate <family>` runs the harness. The labelled pairs come from
  the host's `:calibration_input` MFA and the run is recorded through the host's
  `:calibration_store` resource; `--dry-run` records nothing.

## The judgment surfaces (`AshJudgments.A2ui`, optional `ash_a2ui`)

- Bind a surface in your **web layer**, never in a resource: `use AshJudgments.A2ui.Verdicts,
  resource: MyApp.SystemOne.Banding` expands to an `AshA2ui.Standalone` module. The five are
  `Verdicts`, `BandTables`, `Certifications`, `Calibration` and `Facts`.
- Each surface's moduledoc is its contract: the read and the actions it names on your resource.
  Declare them; a missing one is a compile error from `ash_a2ui`'s verifiers, by design.
- Every act is an action on your resource under your policies. Make the person acts human-only:
  `:record_verdict` (run `AshJudgments.HumanVerdict.FromBanding`), `:certify_and_publish` (yours,
  since publication is your decisions store), and `:revoke`.
- A read that crosses two of your resources (`:awaiting_verdict`, `:awaiting_certification`) is
  yours to declare. For `:awaiting_verdict` use the package's filter, `prepare
  {AshJudgments.HumanVerdict.AwaitingVerdict, verdict_resource: …, judgment_resource: …}`: it
  lists one banding per subject, question and unchanged state, and `FromBanding` settles the
  others with the same verdict. Elsewhere, name your resource literally in `exists/2`.
- `:record_verdict` takes `record_id`, `answer` and `why`. Declare `answer` as `:atom` with
  `constraints: [one_of: [:yes, :no]]` for yes/no questions, so the prompt is a Yes/No picker.
- The verdicts surface shows the banding fragment's `:subject`, `:question_text`, `:lean` and
  `:judged_excerpt` (`:judged_text` in the detail). Set `config :ash_judgments, :review_source`
  to a module implementing `AshJudgments.Banding.ReviewSource`: it opens the sealed state as
  the actor through your own key handling, and returns the DMN of the band-table version a
  banding recorded (never the one published now). Never decrypt in the package or with
  `authorize?: false`.

## Telemetry

- Every event is `[:ash_judgments | ...]`, carries `region`, and the judge events carry
  `rung: :system_one`. `AshJudgments.Telemetry.events/0` is the registry.
- No state, answer text or other payload ever rides in telemetry metadata or spans. Keep
  it that way in handlers you attach.

## The BPMN and evidence bridges

- `bpmn_callable? true` on a question generates `judge_<name>_signals`, which returns a
  string-keyed, scalar-valued map for an `ash:call` service task to promote. Promote
  that map, never an answer struct.
- `judge_<name>`, `judge_<name>_matrix` and `judge_<name>_signals` take an optional
  `invocation_id` argument. It is recorded on the ledger row as `invocation_id` (agent-run
  lineage), linking the row to the invocation that asked; a key a host already put in
  `context[:judgments]` is overridden by the argument when both are given.
- `Bridge.Evidence.artifact_attrs/3` builds an `EvidenceArtifact` create input from a
  recorded judgment and its banding. It never writes: the host creates the artifact
  through its own domain.

## Mix tasks

- `mix ash_judgments.judgments.lock` regenerates `priv/judgments/lock.json`. Run it after
  a reviewed question change that bumps `version`; a hash change without a version bump
  fails compilation.
- `mix ash_judgments.shadow --family F --candidate PROFILE` re-runs recorded `:live`
  judgments through a candidate profile as `mode: :shadow` rows. It needs the host's
  `:state_resolver` and `:shadow_runner` seams and refuses without them.

## For hosts defining the ledger resource

- The package supplies a `Spark.Dsl.Fragment`, not a persisted resource. Define the
  resource on **your** platform base so **your** audit, tenancy and ownership apply.
- Every row carries its region and zone context — a total that quietly covers one region
  is the most common data error. Telemetry, ledgers and calibration runs are all
  region-dimensioned.
- Fixtures in tests are synthetic and free of customer content, always.
