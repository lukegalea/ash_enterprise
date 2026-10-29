# ash_enterprise_battery

The **cross-substrate integration battery** for the ash_enterprise platform
(ADR 0009 family): the flows that span two or more `ash_*` substrate
packages, exercised against the battery's OWN reference instantiation of
those substrates — its own test domain, its own resources, its own
migrations, its own Postgres database (`platform_battery_test`).

Single-dep semantics do **not** live here; they live in each dep's own
suite. This app exists to prove the seams a dep suite cannot see.

## Run it

```sh
mix deps.get
mix platform_battery
```

The task:

1. creates the `platform_battery_test` database if missing
   (idempotent),
2. runs pending migrations (idempotent),
3. runs the battery's ExUnit suite in-process,
4. exits nonzero on any failure.

Deterministic: no network, no host configuration beyond the standard
`PGHOST` / `PGPORT` / `PGUSER` / `PGPASSWORD` env vars (defaults
`127.0.0.1:5432`, user `postgres`, trust auth). Postgres 18 floor
(`btree_gist`, `vector` and `ash-functions` are installed by the
migrations); `xmllint` (libxml2) must be on `PATH` — `boxic_dmn` shells
out to it.

A second consecutive run is green: database setup and migrations are
no-ops on an already-migrated database, and the suites clean the tables
they touch.

## Scenarios (`test/base_integration/`)

| File | Seam |
| ---- | ---- |
| `judgment_banding_evidence_test.exs` | **judgment → banding → evidence.** An ash_evidence document version + parse run addresses atoms; a System One `Evidence` question is judged over them (the observation cites the atoms, `answer_kind :evidence`); `AshJudgments.Bridge.Dmn.inputs/2` flattens the answer; a PUBLISHED ash_decisions band table (landed via `AshDecisions.BandTable`) is evaluated through `AshDecisions.Evaluator` (which records the evaluation); the banding row records the definition's key/version/content hash, the evaluation id and the engine's matched rule ids; the `:admit` band materialises a fact whose admission provenance and state digest tie back to the recorded observation. Negative half: a low-support answer bands to `:review`, proposes no fact value, and materialises nothing. |
| `process_decision_routing_test.exs` | **process ↔ decisions.** A BPMN `businessRuleTask` carries a decision *reference* (`battery_amount_tier`), verified at publish time against the ash_decisions-backed `AshBpmn.DecisionResolver`; starting an instance evaluates the declared FEEL input off the subject through `AshDecisions.Evaluator`, promotes ONE declared scalar signal (`tier`) onto the token, and the gateway routes on `routing.tier`. Asserted: both branches from the same diagram+decision, the promoted token signal, and the recorded evaluation row (definition key + version + engine's matched rule ids + inputs) that carries the identity across the seam. |
| `ledger_projection_compliance_test.exs` | **ledger → projection → compliance finding.** A vendor-review event is committed to the BIZEV ledger; the ledger's projector (`use AshDiscreteBusinessEvents.Projections`, drained per region) folds it into the `VendorState` projection; the compliance projector (`AshCompliance.Projector`) translates the review into a `Finding` by evaluating the ACTIVE `PolicyBundle` — compiled from an `ash_rules` rule set serialized through the compliance plane — with facts read off the BIZEV projection. Asserted: the finding's grain, gap, severity and bundle hash; the recorded `ComplianceEvaluation`; and the seam property — correcting the LEDGER (a new superseding event, drained) flips the finding to compliant. A vendor with no projected state lands `:error`, never `:compliant`. |
| `mdm_survivorship_test.exs` | **MDM survivorship over business events.** Raw source records land through the BIZEV `SourceRecord` path (two sources, same vendor); the mappings-as-data engine maps each landed payload into version-pinned canonical fields (provenance joins to the active `MappingVersion` content hash); the mapped records land on the ledger; `AshMdm.Match.score/3` scores the staged record against the golden candidate with rules-as-data and the pair is recorded as a `MatchCandidate`; `AshMdm.Survivorship.resolve/2` picks per-attribute winners (`source_rank`, `most_recent`) with provenance — and the golden `Vendor` record is written from the fold. |

## Layout

```
lib/mix/tasks/platform_battery.ex   the runner task
lib/battery/                        the reference instantiation
  repo.ex, domain.ex
  events/event_log.ex               the AshEvents audit log
  system_one/                       ash_judgments fragments (Judgment, Fact, Banding) + CaseFile (judged Evidence question)
  decisions/                        ash_decisions Definition + Evaluation
  bpmn/                             ash_bpmn Definition/Instance/Token/ProcessEvent + Subject + the three engine seams (Invoker, Resolver, DecisionResolver→ash_decisions)
  business_events/                  BIZEV DSL host (sources+mappings), SourceRecord, Ledger, MappingVersion, VendorState, Projector
  compliance/                       ash_rules rule set, compliance Projector (facts from the BIZEV projection), event log
  mdm/                              ash_mdm Vendor (golden), Mapping, MatchRuleSet, MatchCandidate
priv/repo/migrations/               the reference schema: ported from each substrate's suite migrations (verbatim, renumbered) + codegen for the battery's own resources
test/base_integration/              the scenarios
test/support/                       fixtures (DMN + BPMN documents) and the ReqLLM stub
```

## Pins

The nine substrates are pinned in `mix.exs` exactly as `ash_enterprise`
pins them, and `mix.lock` pins the same SHAs ash_enterprise's lock
resolves (`ash_events` carries the platform's
`temporal-as-of-support-0.7` fork with `override: true`).
