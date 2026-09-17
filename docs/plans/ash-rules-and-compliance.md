# ash_rules and ash_compliance: design and execution plan

Status: **executing — Lanes A/B/C shipped; Lane D (this repository's
integration) landed on the `rules-compliance-integration` branch.** Related:
`docs/Consider elixir's wongi-engine rules engine agains.md`,
`docs/Layered Enterprise Compliance Rules Updated Architecture and Authoritative
Design Sources.md`, `docs/plans/ash-strangler.md`, ADR 0009, ADR 0031,
ADR 0035.

## Decisions already made

- Two new private repos: `lukegalea/ash_rules`, `lukegalea/ash_compliance` (created).
  Documentation written public-ready.
- Wongi engine (`wongi_engine`, MIT, ~0.9.20) is an **optional dependency**; the
  direct-matching evaluator is the default and always available.
- `ash_compliance` ships **no API layer** — no AshJsonApi/AshGraphql exposure.
  Wire format is a host-app concern; the package ships resources, actions and the
  projector only.
- `ash_strangler` gains the durable ledger and ingester codegen with **zero new
  hex deps** (verified feasible against source; see below).
- Screenshots/marketing assets produced live from the ash_enterprise demo app
  (same pattern as ash_bpmn's `dev/` demo host).
- Strangler PR: open against main, Luke merges.

## Package boundaries (from the wongi doc, confirmed by source review)

| Package | Depends on | Owns | Never does |
|---|---|---|---|
| `ash_rules` | ash, spark; `wongi_engine` optional | Rule IR, fact schema DSL, Evaluator behaviour + adapters, validation, explanation types | Events, persistence, catalogs |
| `ash_compliance` | ash_rules, ash_events, ash_events_projections | Control plane, ComplianceProjector, findings/evaluations/evidence, OSCAL import/export | Legacy capture, user actions, API exposure |
| `ash_strangler` | ash, postgrex, spark | Legacy CDC, ledger table + trigger, drain infra, `gen.ingester` codegen | Audit semantics, compliance, event-log ownership |
| `ash_enterprise` (host) | all | IngestLegacyChange action, actor resolution, tenancy mapping, API exposure | Re-derived library machinery |

## Source-review findings (verified, not assumed)

### wongi_engine (`/tmp/opencode/wongi_engine`)

- Public API: `Wongi.Engine.new/0`, `compile/2`, `compile_and_get_ref/2`,
  `assert/2,4`, `retract/2,4`, `select/2,3`, `tokens/2`, `productions/1`.
- DSL (`use Wongi.Engine.DSL`): `rule(name, forall: [...], do: [...])` with
  matchers `has/3,4` (alias `fact`), `neg/3` (alias `missing`), `ncc/1`, `any`,
  `assign`, `once`, filters (`equal/diff/greater/less/gte/lte/in_list/not_in_list`,
  function filters), aggregates, and `Generator` actions for derived facts.
  Variables via `var/1`, `:_` wildcard. Derived (generated) facts are retracted
  automatically when their support disappears — the truth-maintenance property
  the adapter relies on.
- Implication: the adapter compiles one IR rule → one wongi rule per LHS
  pattern-group with a Generator RHS; provenance comes from `tokens/2` on the
  production ref, translated to domain rule ids (never engine refs).

### ash_events_projections (`/tmp/opencode/ash_events_projections`)

- `use AshEvents.Projections.Projector, name: "..._v1", event_log: ..., projection_resource: ...`
  with `grain/1` (atom or fn event → grain key | nil) and `project Resource, :action, handler`
  (arity 1 stateless, arity 2 stateful — gets `event, current_row`; serial
  processing ⇒ no read-modify-write race).
- Handlers return ops lists (`{:set, f, v}`, `{:increment, f, n}`, ...); the
  Server applies them via the injected `:upsert_grain` / `:apply_projection_ops`
  actions, checkpoints per batch, dead-letters poison events keyed
  `{projection_name, event_id}`.
- Free for the ComplianceProjector: checkpoint/resume, DLQ + replay, blue/green
  versioning (rule change = projector name bump + `rebuild`), `time_travel`
  (as-of for auditors), `verify` (drift detection), `lag`, `NotifyProjectors` →
  PubSubListener fast path.
- Hazards: `Operations.Gaps` bigserial late-commit ordering; mitigate by keying
  checkpoint drain to the tenant hash chain where possible, else accept the
  documented gap-detection net.
- `AttachProjection` exposes projection fields as calculations on ordinary
  resources — the "compliant? / gap_count on Customer" story with zero
  engine-in-the-query-path.

### ash_strangler (`deps/ash_strangler`)

- `AshStrangler.Migration.statements/1` composes view + triggers +
  `Sql.Notify.build/1`; both `gen.migration` and `install` flow through it —
  the single insertion point for ledger DDL.
- `Sql.Notify` already builds the AFTER trigger on the legacy base table and
  keeps the payload key-only (7999-byte ceiling aborts the *legacy* txn). The
  ledger trigger writes the durable row; the notify payload gains only
  `wake:<ledger_id>` — same ceiling discipline, now pointing at durable state.
- `entities.ex` carries `notify?: false` on Source — `ledger?: true` slots in
  beside it, with a verifier: `ledger?` requires `notify?` (wake-up without
  notify is pointless) and one ledger table per relation (shared across
  resources mapping the same twin, keyed by `source_schema.source_table`).
- `gen.twin` / `gen.migration` mix tasks establish the codegen pattern
  (compile, read DSL, render, write into host `priv/repo/migrations`);
  `gen.ingester` follows it, writing into `lib/` instead.
- Listener re-reads through Ash (`Ash.get/3` with `authorize?: false` or system
  actor) and synthesizes notifications; with `ledger?` the listener also nudges
  the drain worker instead of only rebroadcasting.

## ash_rules design

### Serializable rule IR (data, never quoted AST)

```
AshRules.Ir.Rule          # id, revision, applicability(target expr), predicates,
                          # outcome, severity, combining metadata, control mappings,
                          # evidence requirements, message template, remediation ref,
                          # provenance/source citations
AshRules.Ir.FactSchema    # predicate name, value type, cardinality, source/provenance,
                          # dependencies, tenant scope, missing-data semantics
                          # (absence = false | unknown | no-fact), sensitive?
AshRules.Ir.Bundle        # rules + fact schema revision, content hash, compiler version
```

JSON codec in both directions. `AshRules.Ir.decode/1` validates on admission.

### Outcome lattice

`compliant | noncompliant | not_applicable | unknown | error` — `unknown` (facts
missing) and `error` (evaluation failed) never collapse to compliant. Overall
status = aggregation over requirement results after valid waivers.

### Combining semantics (XACML-derived)

Rule sets declare an explicit combining algorithm: `deny_overrides` (default for
compliance), `permit_overrides`, `first_applicable`, `only_one_applicable`.
Truth-table unit tests assert each algorithm's full lattice, not samples.

### Spark DSL → IR

```elixir
defmodule MyApp.Compliance.Rules do
  use AshRules

  fact_schema do
    fact :status, :atom, one_of: [:active, :suspended]
    fact :jurisdiction, :atom
    fact :has_valid_kyc, :boolean, missing: :unknown
  end

  rule "active regulated customer requires valid KYC",
    id: "kyc.valid_required",
    severity: :medium do
    when_requires has(:customer, :status, :active),
                  has(:customer, :jurisdiction, :regulated)
    fails_when neg(:customer, :has_valid_kyc, true)
    outcome :noncompliant, gap: "kyc.valid_required"
  end
end
```

Compile-time verifiers (Cedar pattern — validate before activate, never at
evaluation): every predicate exists in the fact schema with matching type;
variables bind; no undeclared optional access; outcome/severity in domain;
combining metadata present at every level. Tenant-authored rules enter as decoded
IR and pass the same verifier at admission — no `Code.eval`, no persisted AST.

### Evaluator behaviour

```elixir
defmodule AshRules.Evaluator do
  @callback evaluate(bundle(), facts(), opts()) ::
              {:ok, AshRules.Result.t()} | {:error, term()}
  # Result: per-requirement outcomes, derived facts, missing facts,
  # provenance graph (rule revision → control mapping → consumed facts),
  # bundle + schema revision, determinism seed
end
```

- `AshRules.Evaluator.Direct` — pattern matching over the IR; default, no deps.
- `AshRules.Evaluator.Wongi` — compiles IR to triples/matchers/Generator
  productions; behind `Code.ensure_loaded?(Wongi.Engine)`; provenance from
  production tokens mapped to domain rule ids.
- Both must produce identical results on the same bundle + facts (contract test
  suite runs every golden case through both when wongi is available in dev).

### Testing methodology

- **Golden tests**: fixed bundle + fact snapshot → expected findings + traces,
  asserted byte-stable.
- **Determinism**: repeated evaluation (n=100) of random bundles/facts produces
  identical results; property-based (StreamData) generation of fact sets.
- **Truth maintenance** (wongi adapter): retract a premise, assert derived facts
  disappear.
- **Golden parity**: direct vs wongi equivalence across the property corpus.
- **Validation**: every verifier has a negative test quoting its refusal.
- Benchmarks (production gate): realistic fact/rule counts, join cardinality;
  p95 latency + memory budgets recorded in `documentation/topics/performance.md`.

## ash_compliance design

### Control plane resources (OSCAL-inspired)

`Catalog`/`CatalogVersion`, `Control`/`ControlRevision`, `Profile`/
`ProfileRevision` (include/exclude/parameterize/refine/supplement/replace/waive
operations), `TenantPolicySet`, `PolicyOverride`, `RuleSetRevision`
(draft→validated→approved→active→retired/revoked), `PolicyBundle` (immutable,
content-hashed, OPA-style manifest revision), `ControlMapping`.

Layering precedence fixed: non-waivable global > global mandatory >
jurisdiction/profile refinements > tenant strengthening > approved
replacements/waivers > tenant supplements; explicit combining algorithm within
each level. Compilation resolves all layers into an immutable effective bundle —
never ad-hoc inheritance at evaluation time.

### Data plane: ComplianceProjector

An `ash_events_projections` Projector over the finding grain
`[organization_id, control_id, subject_type, subject_id]`:

- `grain/1` resolves the subject from the event
- stateful arity-2 handlers: hydrate facts (from event data + AttachProjection
  reads), call the `ash_rules` evaluator against the active bundle, translate
  the result into ops (`{:set, :status, ...}`, `{:increment, :breach_count, 1}`, ...)
- Finding resource = ProjectionResource (current state);
  `ComplianceEvaluation` = append-only record (bundle revision, fact snapshot
  hash, outcome, missing facts, evaluator version, correlation id) — the auditor
  truth, deliberately distinct from the projection (projection = now,
  evaluation = what the engine decided and why)
- `EvidenceArtifact` immutable references (hash, media type, collector, chain of
  custody) per SP 800-53A
- Rule change = projector name bump + blue/green rebuild; shadow evaluation =
  run v(n+1) alongside, diff findings
- `AttachProjection` on host resources gives `compliant?`/`gap_count` as
  ordinary calculations — no rules engine in the query path

### OSCAL import/export

Mix tasks for catalog/profile/component-definition JSON import/export;
identifiers, parameters, provenance and revision lineage preserved at the
boundary; internal model stays relational/ergonomic.

### Testing

- Replay-determinism: same bundle + event range → identical findings and
  evaluations (the acceptance bar).
- Tenant isolation: tenant A's override cannot alter tenant B's findings;
  asserted, not assumed.
- Missing evidence → `unknown`, never `compliant`.
- Bundle activation atomicity + rollback; projector crash recovery via
  checkpoint/DLQ; `verify` drift detection exercised.
- Waiver semantics: bounded time + scope, approver recorded, compensating
  controls required.

## ash_strangler ledger upgrade (PR scope)

1. `ledger?: true` on `source` (requires `notify? true`; one ledger table per
   relation): `gen.migration` emits `legacy_change_events` (id bigserial,
   source_system, source_schema, source_table, operation, primary_key,
   old_row/new_row jsonb, changed_columns, transaction_id, transaction_timestamp,
   source_user, source_request_id, source_correlation_id, actor_confidence,
   emitted_at, processed_at nullable) + AFTER trigger writing the row
   transactionally, then `pg_notify(channel, 'wake:<id>')`.
2. `mix ash_strangler.gen.ingester MyApp.Resource` generates into the host app:
   ingestion action skeleton (runs ordinary Ash actions on the canonical
   resource; actor = `resolve_actor/1` stub returning `{:ok, actor} |
   :unattributed`), idempotent Oban cursor-drain worker.
3. Listener: unchanged re-read behavior; with `ledger?` it additionally nudges
   the drain worker. Sweep worker (or cron on the Oban job) is the recovery net.
4. Verifier updates + `check` task extensions (unprocessed-ledger backlog
   reporting). Tests follow existing SQL-rendering test patterns. Docs topic +
   README section. CI unchanged.
5. The ledger table is plain infrastructure (no Ash resource in the library) —
   a host app may wrap it if it wants querying.

## ash_enterprise integration PR

Status: **shipped on the `rules-compliance-integration` branch**; the
authoritative record of what this slice decided is
[ADR 0035](../../docs/adr/0035-compliance-is-projected-from-events.md) — the
compliance ADR is numbered 0035, not 0033; 0033 went to the A2UI experience
layer while this lane was in flight.

- Deps: `{:ash_rules, github: "lukegalea/ash_rules"}`, `{:ash_compliance, github: ...}`,
  strangler ref bump. — **done** (`mix.exs`; `ash_strangler` pins
  `branch: "ledger-and-ingester"` until PR #5 merges).
- One vertical slice: customer KYC compliance (5–10 facts, catalog + profile +
  one tenant override + one bounded waiver, ~15–25 rules covering the POC list
  from the design doc). — **done**: ten facts, thirteen controls, four rule
  modules across the layers, the profile refining the strengthening rule, the
  bounded waiver, revision 2 drafted for the replay test. Seeds in
  `AshEnterprise.Compliance.Seeds` / `mix ash_enterprise.compliance.seed`.
- Generated ingester wired to a real legacy resource; system-actor attribution;
  ash_events metadata carrying the source envelope. — **done**
  (`AshEnterprise.Ledger.UserIngestion` / `UserDrainWorker`; the envelope rides
  the audit metadata under `ledger_*` keys; `ledger? true` on
  `AshEnterprise.Legacy.User`).
- `AttachProjection` on Customer for `compliant?`/gap counts; findings visible
  in admin LiveView (screenshots for both repos taken here). — **done, with a
  deviation worth knowing**: `AttachProjection` point-lookups assume one stats
  row per grain; the finding grain is per *control*, so a subject's status is a
  fold across rows, not a lookup. `ProjectedUser` exposes `kyc_status`,
  `compliant?` and `gap_count` as batched module calculations over the finding
  projection instead. Findings/evaluations/bundle/rule-set/catalog/profile
  surfaces are A2UI (`/app/compliance/*`, behind `ComplianceAuth`); screenshots
  are a follow-up.
- COMPLIANCE.md/controls.json updated **only** through QUESTIONS.md pipeline;
  new ADR 0035 "compliance is projected from events"; roadmap entries;
  `docs/plans/` updated to point at shipped repos. — **ADR and plans done;
  COMPLIANCE.md/controls.json untouched** (no repo-root COMPLIANCE.md or
  ROADMAP.md exists on this branch to regenerate; flagged for the pipeline
  owners rather than hand-edited).
- Prose pass (repo-wide, including site/): remove temporal/metacommentary and
  mannered constructions; plain declarative technical voice; regenerated docs
  must still pass the roadmap/controls CI checks. — **deferred**: new files are
  written in the house voice; the repo-wide pass stays its own change.

## Execution order and lanes

1. ~~Research~~ (done — this document records the findings).
2. Lane A: `ash_rules` repo (IR → DSL → verifiers → direct evaluator → wongi
   adapter → tests → docs/README). Critical path; independent.
3. Lane B: `ash_strangler` ledger PR (parallel to A; independent repos).
4. Lane C: `ash_compliance` (starts when A's IR + evaluator behaviour freeze).
5. Lane D: ash_enterprise integration + demo app slices + screenshots.
6. Lane E: marketing/docs/prose pass across all repos + site.

Gates: `mix precommit` (or repo equivalent) green before every push; strangler
`check` before any demo phase change; replay determinism is the acceptance bar
for Lanes A/C.

## Infra note

Two orchestrator crashes orphaned all background specialist sessions during
research; research was completed directly in-session instead. Build lanes will
be attempted as foreground specialist dispatches with this fallback available.
