# ash_enterprise_battery

The **cross-substrate integration battery** for the ash_enterprise platform
(ADR 0009 family): the flows that span two or more `ash_*` substrate
packages, exercised against the battery's OWN reference instantiation of
those substrates — its own test domain, its own resources, its own
migrations, its own Postgres database (`platform_battery_test`, or the one `PLATFORM_BATTERY_DB`
names).

Single-dep semantics do **not** live here; they live in each dep's own
suite. This app exists to prove the seams a dep suite cannot see.

## Run it

```sh
mix deps.get
mix platform_battery
```

The task:

1. creates the `platform_battery_test` database if missing
   (idempotent). Set `PLATFORM_BATTERY_DB` to use another name, so a second checkout or
   a CI worker can share one Postgres server without sharing tables,
2. runs pending migrations (idempotent),
3. runs the battery's ExUnit suite in-process,
4. exits nonzero on any failure.

Deterministic: no network, no host configuration beyond the standard
`PGHOST` / `PGPORT` / `PGUSER` / `PGPASSWORD` env vars (and the optional
`PLATFORM_BATTERY_DB`; defaults
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
| `invocation_approval_test.exs` | **governed invocation ↔ process approval.** An `ash_agent` invocation (`Battery.Execution.Invocation`, the `AshAgent.Invocation` fragment on a plain resource) of a four-eyes target waits on a standalone ash_bpmn `HumanTask`, opened in the request's transaction through `AshBpmn.Changes.RequireApproval` (candidates from the declared approver role, the requester excluded); a candidate decides it through `AshBpmn.complete_task/2`, never `on_complete`, and `apply_decision` reads the decision off the task. Asserted: candidacy and exclusion; the RFC 9396 `authorization_details` and their JCS digest; the approved row runs once; a subject amended while the approval is pending, or after it is given, leaves the row `stale` and the subject untouched; a rejection is applied as one. |
| `agent_human_wait_test.exs` | **agent run ↔ process task: a run waits on a person.** An `ash_agent` run (`Battery.Execution.Run`, the `AshAgent.Run` fragment, with `Step` and `AgentVersion`, a scripted model through `Battery.Execution.Runtime`) calls a tool that asks the person it acts for a question (`Battery.Execution.HumanInput`, `intent: :propose`). The tool returns a `Dispatch`, so its invocation is `dispatched` (no lease, a deadline), and the question's standalone ash_bpmn `HumanTask` opens in the dispatch's transaction through `AshBpmn.Changes.RequireApproval`, with the invocation's owner as its only candidate. Asserted: after days of moved clocks, a step, an execute, a collection and a reconcile all skip, and no job exists for the run or its call; no model call is made; nobody but the candidate answers; the answer, collected through `complete_external`, is the invocation's `result`, and the run's next step reads it and completes; a withdrawn question fails the call, and the run carries on. |
| `process_service_task_invocation_test.exs` | **process service task ↔ governed invocation.** A BPMN service task naming a declared `ash_agent` target (`Battery.Bpmn.Invoker`'s `@targets`) runs it through its invocation (`Battery.Execution.ProcessTask`): keyed `bpmn:<instance>:<token>:<node>` from the engine's invocation key, its parent the instance and node, asked for and run as the member who started the instance, executed inline in the advance job. Asserted: the key and parent; the governed `acknowledge` runs only through its row, as the starter; a redelivery of the node under the same engine key gets the row back and runs nothing; a parallel branch whose check refuses with `AshAgent.BusinessError` (`failure_class :business`) takes its error boundary on that code while the sibling branch completes, and the two branches rejoin at a parallel join that fires once. |
| `mdm_survivorship_test.exs` | **MDM survivorship over business events.** Raw source records land through the BIZEV `SourceRecord` path (two sources, same vendor); the mappings-as-data engine maps each landed payload into version-pinned canonical fields (provenance joins to the active `MappingVersion` content hash); the mapped records land on the ledger; `AshMdm.Match.score/3` scores the staged record against the golden candidate with rules-as-data and the pair is recorded as a `MatchCandidate`; `AshMdm.Survivorship.resolve/2` picks per-attribute winners (`source_rank`, `most_recent`) with provenance — and the golden `Vendor` record is written from the fold. |
| `agent_start_process_test.exs` | **agent run ↔ process: a run starts a process through an approved invocation.** An ash_agent run calls the `start_process` tool (`Battery.Execution.StartProcess`), a governed target that asks the person the run acts for to confirm (`approval: :confirm`) and writes only here; only a key on the allowlist may be named. Asserted: an unlisted key is refused where the request is made, with no task and no instance; before confirmation there is no instance and the request holds an approval task for that person alone, bound to the active release; once confirmed and applied the target runs once, as them, and there is one instance on the named record; running the row again starts nothing; the run reads the instance's id as the tool call's result. |
| `process_agent_run_test.exs` | **process ↔ agent run: a process hands work to an agent and waits for it.** A service task starts a run as the member who started the instance, keyed by the engine's invocation key; a receive task waits for the run's CloudEvents envelope (`Battery.Execution.RunFinished`), written in the transaction in which the run reaches a final state, correlated on its id; a second service task reads how the run ended and a gateway routes on it. Asserted: the run's key and owner and that a redelivery starts none; the token parks listening for this run; the envelope names the run and epoch and carries nothing the run said; the engine's correlator wakes the process once, and the same envelope again or another run's moves nothing; a cancelled run takes the other branch. |
| `planning_snapshot_check_test.exs` | **planning model → solve → checker → candidate → snapshot replay.** A published ash_planning model version pins its hashes into an `AshOpenLineage` snapshot; a backend (the package's Fake) solves; an independent checker judges the candidate; the snapshot is serialised, reconstructed from ids and hashes alone, and its digest verified, and the cross-host golden digest is re-asserted. Only ids, hashes and digests cross between the substrates; no database fixtures. |
| `release_manifest_test.exs` | **release manifest ↔ approval, and a pinned decision for an older case.** When a release covers a target (`AshAgent.ReleaseManifest`) the four-eyes request records it and the approval binds its digest into the RFC 9396 `authorization_details`; a different release made active while the approval waits leaves the row `stale` (`manifest_changed`) and nothing runs. A BPMN business rule task's decision is resolved by a host resolver that reads the subject: a subject pinned to decision version 1 is answered by version 1 after version 2 is published, and one nothing pins is answered by version 2. |
| `operations_webhook_process_test.exs` | **provider webhook ↔ process receive task.** A provider's signed webhook, posted through `Battery.Operations.Router` (no body parser before the ingress), records a `Delivery` holding the activation id and nothing else; a follow-up reads the provider by that id through a declared operation and writes a CloudEvents envelope from THE READ, which an ash_bpmn receive task, correlated on the id, wakes on. Asserted: the token parks on the id; a signed delivery is 204 `:enqueued` with one delivery and no provider request; the follow-up makes one read and one envelope; the nudge is not a fact (the webhook says `revoked`, the read says `active`, the process takes the `active` branch); a redelivery is `:duplicate` and moves nothing; a bad or stale signature is 401 and an oversized body 413, recording and reading nothing; telemetry carries the provider, outcome and status only. |
| `operations_ambiguous_invocation_test.exs` | **ambiguous provider create ↔ governed invocation reconcile.** A governed `Submission.submit` calls a non-idempotent declared operation keyed by the invocation key; the provider takes it and loses the answer. Asserted: the row is `outcome_unknown` (`ambiguous`) after one send and no wait; a redelivery skips; the reconciler asks the provider by the key, finds one activation and settles the row `succeeded` with it, still one send; reconciling again moves nothing; the transition is recorded once in the AshEvents log and once as OpenLineage COMPLETE, with no actor, key or id in the lineage. Negative halves: no match or two leave the row `outcome_unknown` for a person, never `failed`; a 429 is `transient` and deferred, never `outcome_unknown`. |
| `operations_disclosure_decision_test.exs` | **disclosure gate ↔ published decision.** A `discloses? true` operation asks `Battery.Operations.Gate` before it sends; the gate evaluates the latest PUBLISHED `battery_disclosure_permitted` DMN through `AshDecisions.Evaluator` over three inputs of its own choosing (the submission's data class and consent, the transport's residency) and nothing from the payload. Asserted: a refusal sends nothing and names the policy version (`consent_required@v1`); the Evaluation is recorded with definition, version and matched rules; a permit sends once; publishing v2 flips the same call with no code change; through an invocation a refusal is a final `denied` failure; residency comes from the transport, not the caller. |
| `evidence_archive_chain_test.exs` | **evidence archive ↔ audit chain.** An organization's hash-chained audit log (`ash_events_chain`, `Battery.Audit.EventLog`) is verified daily and each verification recorded as `ash_compliance` evidence for CC7.2. Past the ninety-day window, `AshEvents.Chain.Retention` moves the chain's old events to their archive and `AshCompliance.Ownership.Retention` moves the superseded evidence to `Battery.Compliance.ArchivedEvidence` (`use AshCompliance.Resources, {:evidence_archive, ...}`), each by a verified copy recorded in the one run ledger (`Battery.Audit.ArchiveRun`). Asserted: the chain verifies across the move, hot and archived together; a past period's evidence and the criterion's freshness at its end read the same after the move, from the archive, with every artifact's integrity verified; the sweep's current answer is unchanged; one verified run per store. |

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
  audit/                            ash_events_chain: a hash-chained audit log, its archive and the run ledger evidence moves share
  compliance/                       ash_rules rule sets (vendor review; intake revisions 1 and 2), compliance Projector (facts from the BIZEV projection), event log,
                                    Applicant + ScheduledActivation (host subjects), Activation (the timer process's service tasks), Standing (as-of answer: compiled revisions → rules → DMN),
                                    ArchivedEvidence (the evidence archive)
  mdm/                              ash_mdm Vendor (golden), Mapping, MatchRuleSet, MatchCandidate
  execution/                        ash_agent Invocation (fragment, audited and lineage-emitting), its identity and digest key, a Referral target, the Members who ask and approve, and the approval seam to ash_bpmn
  operations/                       ash_operations: the declared Registry (spec-pinned), its Transport, FailureClass and disclosure Gate (reads a published DMN), the Submission a governed call acts on, the signed Webhook + Router, Delivery, FollowUp and the ActivationSettled envelope
  lineage/capture.ex                an ash_open_lineage transport that keeps events in memory for the test to read (+ a correlation provider)
priv/operations/                    the vendored synthetic provider spec the Registry is pinned to by sha-256
priv/repo/migrations/               the reference schema: ported from each substrate's suite migrations (verbatim, renumbered) + codegen for the battery's own resources
test/base_integration/              the scenarios
test/support/                       fixtures (DMN + BPMN documents), the ReqLLM stub and the Req.Test provider stub (operations_stub.ex)
```

## Pins

The substrates (nine, `ash_agent`, `ash_operations` and `ash_events_chain`) are declared in `mix.exs` exactly as
`ash_enterprise` declares them (`ash_events` carries the platform's
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

**`ash_compliance` is locked at `9ff9cfb`, in the root and here.** That is
ash_compliance `main` after PR #31 (`AssessmentResults.validate/1`) merged, with
PR #30's OSCAL assessment results and
PR #28's evidence archive and verified move, which
`evidence_archive_chain_test.exs` runs. It also carries the temporal rule-set
revisions and `activate`'s `effective_at` (the dated-activation seam
`process_activation_reevaluation_test.exs` runs). It is declared in `mix.exs`
exactly as the root declares it, with no `ref:` and no `override:`, so an app
that takes the battery as a test dependency resolves its own `ash_compliance`,
not one the battery picked. The declared layer schemes are not exercised here.
Their nullable `scheme` columns (`20261025000616`) are ported anyway, so the
battery's schema matches the code a host locking `9ff9cfb` runs.

The temporal migrations are ported verbatim from ash_compliance's suite
(`priv/repo/migrations/2026102500061*`).
