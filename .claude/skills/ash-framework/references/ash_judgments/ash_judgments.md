# Rules for working with AshJudgments

AshJudgments is the System One judgment substrate: declared, typed, calibrated questions
over any Ash resource; answers recorded as observations with full provenance; recorded
judgments turned into DMN inputs, rule facts, process signals and evidence artifacts by
the bridges. Transport is upstream `ash_ai`'s evaluate action over ReqLLM — this package
ships no HTTP client, provider behaviour or answer types. Read these rules before using
it; they are the package's contract, and most of them are enforced by construction once
the tickets land.

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
  calibration, per family (and per tenant risk tier where needed). A threshold in
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
`ash_compliance`, `ash_events`, `opentelemetry_ash`). A missing dep is a structured
error, never a crash:

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
  inputs (law 2). Bandings are immutable; facts are superseded; certs
  are revoked. The frozen band enum is `admit | review | omit` — never
  `unknown` (that is the ash_rules outcome layer).

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
  inputs (law 2). Bandings are immutable; facts are superseded; certs
  are revoked. The frozen band enum is `admit | review | omit` — never
  `unknown` (that is the ash_rules outcome layer).

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

## For hosts defining the ledger resource

- The package supplies a `Spark.Dsl.Fragment`, not a persisted resource. Define the
  resource on **your** platform base so **your** audit, tenancy and ownership apply.
- Every row carries its region and zone context — a total that quietly covers one region
  is the most common data error. Telemetry, ledgers and calibration runs are all
  region-dimensioned.
- Fixtures in tests are synthetic and free of customer content, always.
