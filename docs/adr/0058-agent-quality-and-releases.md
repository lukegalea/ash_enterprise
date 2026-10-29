# ADR 0058 — Agent quality is measured in a host Quality domain, and a release is a gated, attested manifest

- **Status:** accepted, not built (2026-10-23)
- **Date:** 2026-10-23
- **Decided:** by Luke, 2026-10-23 (host domain, no separate package; deterministic-only gating in the first version)
- **Related:** [ADR 0041](0041-thresholds-are-dmn-earned-by-calibration.md) (calibration earns thresholds),
  [ADR 0047](0047-learning-produces-proposals.md) (learning produces proposals),
  [ADR 0055](0055-consequential-acts-are-governed-invocations.md),
  [ADR 0056](0056-the-ash-agent-package.md)

## Context

Changing an agent's instructions, its model profile, a tool or a decision table can change what it does. Nothing here
says whether a changed agent still behaves before it is live. Verified on 2026-10-23:

- **The only harness is a test helper.** `AshEnterprise.Test.AssistantEval` (`test/support/assistant_eval.ex`) scores
  the assistant on fixed cases and has a `scorecard/1`. `mix ash_enterprise.assistant.eval` writes its results to a
  JSON file under `tmp/`. Nothing records a result, and nothing gates on one.
- **"Evaluation" already means four things.** `Decisions.Evaluation` is a DMN trace, ash_compliance evaluations are
  business assessments, ash_ai's `evaluate` is a typed model call, and `AssistantEval` is the harness.
- **Calibration already exists.** ash_judgments calibration runs and certifications earn band tables
  ([ADR 0041](0041-thresholds-are-dmn-earned-by-calibration.md)); a second calibration store would duplicate them.
- **Pinning exists for one kind of thing at a time.** `Process.Binding` pins a process per tenant and
  `BandTablePublication` pins a band table. `AshEnterprise.Release` is the migration runner. Nothing pins a set of
  processes, decisions, agents and tools that were tested together.
- **Averaged metrics hide hard failures.** Inspect scores an incorrect answer as 0.0 into its averages
  (https://inspect.aisi.org.uk/scorers.html.md, read 2026-10-21), so one prohibited effect in a hundred cases still
  averages to 99%.

## Decision

**Agent evaluation lives in a host `AshEnterprise.Quality` domain. Only deterministic assertions gate a release in the
first version. A release is an immutable manifest of digests, gated by suite runs on exactly that manifest, approved by
a second person, exported as an in-toto attestation, and promoted by moving one pointer.**

### Where it lives

`Quality.Suite`, `Quality.SuiteRun` and `Quality.CaseResult`, and `Execution.ReleaseManifest`, are host resources on
the platform base. There is no separate evaluation package: it would duplicate ash_judgments calibration and add a fifth
meaning of "evaluation". The executor that makes a case effect-free is part of the invocation fragment in `ash_agent`
([ADR 0056](0056-the-ash-agent-package.md)), because it decides what an invocation does in `:eval` and `:shadow` mode.
If a second host needs suites or manifests, they can move into the package as fragments then.

UI labels keep the products apart: "Agent evaluation" for suites, "Decision trace" for DMN evaluations, "Compliance
evaluation" for ash_compliance.

### Suites and runs

| Resource | Holds |
|---|---|
| `Suite` | key and version, `draft → published → retired`; cases in Inspect's `Sample` shape with a stable id, plus fixtures, a split (`dev` or `holdout`) and tags such as `injection`; assertions from a closed deterministic vocabulary; scorers (module digests or ash_judgments question versions); per-suite thresholds and primary metric; provenance (source, usage terms, consent basis, permitted use); content hash. Publishing freezes the cases |
| `SuiteRun` | the suite, the candidate's digest (a manifest digest; for ad hoc prompt experiments, a draft agent version's hash), the mode (`offline`, `replay`, `shadow`, `adhoc`), status, and a summary with quality and safety in separate lanes |
| `CaseResult` | per case and epoch: status (`passed`, `failed`, `errored`, `skipped`, `unmeasured`), each assertion's result and whether it is hard, scores with their judgment ledger ids, whether a prohibited effect was hit, the agent run |

The assertion vocabulary is closed: `tool_called`, `tool_not_called`, `args_match`, `prohibited_effect`,
`approval_requested`, `max_steps`, `within_budget`, `process_transition`, `schema_valid`, `output_matches`, `cites`.

**Effect-free by construction.** A case runs as an ordinary agent run with `mode: :eval`, as an evaluation automation
principal whose grants exist only in a synthetic evaluation tenant. The executor runs read targets and answers every
other target from the case's fixtures, marked simulated; it never claims a target that is not a read. It does not use a
rolled-back transaction, because `before_transaction` hooks and notifiers fire anyway. `prohibited_effect` is then a
query over the run's invocations.

### Scoring and the gate

- **Deterministic assertions gate.** `prohibited_effect`, `tool_not_called`, `schema_valid` and `within_budget` are
  hard: any failure blocks, whatever the averages say.
- **Model-graded scores report and do not gate.** A model-graded assertion is an ash_judgments question version. Its
  score is shown with its certification status beside the deterministic results. Letting a certified judge gate is a
  later decision, recorded as an amendment.
- **Safety is its own lane.** A prompt-injection case is an ordinary case tagged `injection`, scored on state and
  effects: utility, utility under attack, and attack success rate. A run that read untrusted content is marked, and the
  mark is reported in that lane.

`ReleaseManifest.request_release` requires, for each suite the manifest names, a `SuiteRun` on exactly this manifest's
digest with zero hard failures, zero failed `injection` cases and the primary metric at or above the suite's threshold.
It also rechecks that every entry resolves and is published and that tool digests match. A refusal leaves the manifest
`resolved` with the gate's result on it. An `adhoc` run can never satisfy the gate.

### The manifest

| Field | Content |
|---|---|
| `entries` | in-toto `ResourceDescriptor` shape (`name`, `uri`, `digest: %{sha256: …}`) plus a kind: process, decision, ruleset, agent, judgment question, tool, model profile or suite |
| `manifest_digest` | SHA-256 of the RFC 8785 canonical JSON of the entries |
| `status` | `draft → resolved → requested → approved → active`, then `superseded` or `retired` |

`resolve` pins the latest published version of each requested key, and the entries never change after it.
`request_release` runs the gate and opens a four-eyes `HumanTask` that excludes the author. `promote` writes
`Process.Binding` rows and makes the manifest the one active manifest for its key in its organization (a partial unique
identity on `status == :active`). `rollback` promotes an earlier approved manifest. Runs and invocations record the
manifest they ran under, and from then on the manifest digest is part of every approval digest, so a changed decision
version or tool makes pending approvals stale ([ADR 0055](0055-consequential-acts-are-governed-invocations.md)).

### Formats

| Format | Direction | Use |
|---|---|---|
| Inspect EvalLog v2 JSON, as written by `inspect log convert --to json` and validated against `inspect log schema` | import and export | suite runs and case results. No compatibility promise from upstream; NaN and infinities tolerated; the binary `.eval` format is never parsed. The vendored schema gets a `docs/BLEEDING-EDGE.md` row |
| Inspect `Sample` JSONL | import and export | suite cases, with stable explicit ids |
| promptfoo YAML assertions | import only | seeding deterministic cases; never the source of truth |
| in-toto Statement v1 with `ResourceDescriptor` subjects | export | the release attestation, with the gate result as its predicate |

Shadow runs (`mode: :shadow`, no effects) compare a candidate against live traffic before promotion. Splitting live
traffic between versions is later work.

**Seed.** `AssistantEval`'s dimensions become deterministic scorer modules and its cases the first suite. The mix task
writes `CaseResult` rows instead of a JSON file; the existing CI test stays.

## Does it consume ActorContext?

Yes, as every platform resource does, and nothing new queries in a check. Reading suites and runs, starting runs and
publishing suites are three privileges (`quality.read`, `quality.run`, `quality.publish`) in the ordinary grant union.
Candidates run as an evaluation automation principal ([ADR 0043](0043-automation-authority-is-a-grant.md)) whose
`ActorContext` is built from grant rows that exist only in the evaluation tenant, so a case cannot reach live data
even if a fixture is missing. Promotion happens only through the approved `HumanTask`, whose candidacy is the host's
existing task machinery.

## Consequences

- A changed agent, tool, decision or model profile cannot go live without a recorded run on exactly what goes live.
- A prohibited effect or a failed injection case blocks a release regardless of averages.
- "What was live at time T" is the manifest promotion history, read from AshEvents, rather than a reconstruction.
- Model-graded quality is visible but cannot block or unblock a release in the first version; that may let a quality
  regression through which only a judged score would have caught. The trade is deliberate: the judge thresholds in
  public guidance are rules of thumb, not calibrated.
- Running suites costs model calls in the evaluation tenant; budgets on runs ([ADR 0055](0055-consequential-acts-are-governed-invocations.md))
  bound it.
- EvalLog interchange depends on a schema upstream does not promise to keep; a schema change is a vendored-file update
  and a failing import test, not silent drift.

## Reversal

Before any manifest is promoted: delete the Quality domain and the manifest resource and their migrations; the
harness in `test/support` still works. After promotion: stop gating (drop the validation on `request_release`) and
keep the manifests as a record; `Process.Binding` rows written by promotion remain valid pins on their own. Moving the
resources into `ash_agent` as fragments, if a second host appears, is a module move with no table change.
