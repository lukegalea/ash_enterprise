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
| `process_activation_reevaluation_test.exs` | **process timer → dated compliance activation → decision re-evaluation.** A BPMN intermediate timer (`PT1H`, fired on the inline engine's virtual clock) wakes a process whose subject names an APPROVED ash_compliance `RuleSetRevision` and an instant; the `activate_scheduled_revision` service task activates it with that `effective_at` (succeeding the revision in force); the `reevaluate_scope` service task re-answers every applicant in the subject's organization — `AshCompliance.Compiler.compile/1` gathers the revisions in force at the instant, `AshRules` evaluates them over the applicant's facts, and a published ash_decisions table maps the outcome to a standing, recorded per applicant. Asserted: nothing moves before the timer fires; exactly the applicants in scope are re-evaluated; a FUTURE-dated activation leaves today's recorded answers unchanged and changes only the answer as of its instant; a BACKDATED one changes today's answers and the as-of answer after its instant, while the answer before it stands. |
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
  compliance/                       ash_rules rule sets (vendor review; intake revisions 1 and 2), compliance Projector (facts from the BIZEV projection), event log,
                                    Applicant + ScheduledActivation (host subjects), Activation (the timer process's service tasks), Standing (as-of answer: compiled revisions → rules → DMN)
  mdm/                              ash_mdm Vendor (golden), Mapping, MatchRuleSet, MatchCandidate
priv/repo/migrations/               the reference schema: ported from each substrate's suite migrations (verbatim, renumbered) + codegen for the battery's own resources
test/base_integration/              the scenarios
test/support/                       fixtures (DMN + BPMN documents) and the ReqLLM stub
```

## Pins

The nine substrates are declared in `mix.exs` exactly as `ash_enterprise`
declares them (`ash_events` carries the platform's
`temporal-as-of-support-0.7` fork with `override: true`), and `mix.lock`
pins the same SHAs ash_enterprise's lock resolves, with one exception,
`ash_compliance`, below.

This is enforced, not hoped for. `scripts/battery-pins-check.exs` (run from
the repository root, and the first step of CI's battery job) fails, naming
each package, when any package both locks contain resolves to a different
version, ref or git options. Every shared package counts, not just the
substrates: the battery should run the `ash` and `spark` the platform runs
too. To realign after a host bump:

```sh
elixir scripts/battery-pins-check.exs --sync   # copy the host's entries
(cd battery && mix deps.get)                   # fetch, pick up new transitives
elixir scripts/battery-pins-check.exs          # check again
```

A package that genuinely cannot match goes in the script's `@exceptions`
map with its reason.

**`ash_compliance` is ahead of the platform root.** The battery's lock pins
it to `2118d0f`: the temporal rule-set revisions and `activate`'s
`effective_at` (the dated-activation seam
`process_activation_reevaluation_test.exs` runs), with the
activate-succession fix. It is declared in `mix.exs` exactly as the root
declares it, with no `ref:` and no `override:`, so only the lock line differs
and an app that takes the battery as a test dependency resolves its own
`ash_compliance`, not one the battery picked. The root still locks `824e4b9`
(pre-temporal), so `scripts/battery-pins-check.exs` reports this package
until the root takes the same bump. Until then the battery runs code the
platform does not ship yet, which is what the pins check exists to catch.

`2118d0f` is the head of ash_compliance's unmerged `feat/declared-layers`
branch (PR #15), not of its `main`. A ref-less git dependency fetches only
branch heads, so the lock stops resolving if that branch is deleted before
it merges. ash_compliance's `main` (`6a9e21a`) already carries everything
the scenario uses: the temporal revisions, `effective_at` and the succession
fix. The declared layer schemes `2118d0f` adds on top are not exercised
here. Their nullable `scheme` columns (`20261025000616`) are ported anyway,
so the battery's schema matches the code a consuming host that locks
`2118d0f` runs.

The temporal migrations are ported verbatim from ash_compliance's suite
(`priv/repo/migrations/2026102500061*`).
