# System One: design and execution plan

Status: **proposed — nothing is built.** Doctrine drafted (thesis 8, ADRs 0038–0045, all `proposed`); no package,
resource or call site exists. The first wave is landing work that is already written elsewhere, not new building.
Related: [thesis 8](../manifesto/08-models-observe-declarations-decide.md), ADR 0026, ADR 0028, ADR 0029, ADR 0035,
ADRs 0038–0045, [`ash-rules-and-compliance.md`](ash-rules-and-compliance.md).

## What this plan is for

Fast, typed, calibrated model judgments — System One — used as *perception* underneath the platform's declarations,
across three tracks that share one substrate:

- **Development and agent tooling** — advisory signals in `ash_agent_tools` and the agent harness (ADR 0045).
- **Agents in the application** — intent routing one rung below a generative model, extract → verify for prompt-backed
  actions, consistency checks on proposed tool calls.
- **Rules and compliance** — documents → addressed atoms → dual-hypothesis retrieval → adjudication → ledger → band
  table → admission → rule facts → compliance status (ADRs 0040, 0041, 0043, 0044).

The unifying claim is thesis 8's: *models observe, declarations decide.* The model is the replaceable part; the
declared question, the ledger, the band table and the evidence packet are the durable asset.

## Positions proposed (pending review)

These are positions taken in the proposed ADRs — none of them accepted yet. They bind this plan unless review rejects
the ADR carrying them.

- **No bespoke client.** The call is `ash_ai` 1.1.0's `evaluate`; the transport is `req_llm` 1.24.0's `typesafe`
  provider; the answer types are upstream's. This plan writes no HTTP client, provider behaviour or answer type. New
  generic answer kinds (`Evidence`) and hooks (a vetoable `on_tool_start`) are proposed upstream. *(ADR 0039)*
- **Never in a check, never a grant, never in FEEL, rules or projectors.** *(ADR 0038)*
- **Questions are declarations**, content-hashed; the hash is the ledger identity. *(ADR 0039)*
- **The ledger is a host resource on the platform base**, created by a replay-safe action that accepts the answer as
  input; cache, replay and shadow modes; the model digest is part of the verdict's identity; no floating aliases on
  admission paths. *(ADR 0040)*
- **Thresholds are DMN band tables**, published only with a supporting calibration run and activated through the
  approval lifecycle; probabilities stop at the band table. *(ADR 0041)*
- **Local-first per regional stack**; hosted inference is an opt-in, disclosed profile; contract tests against both
  instruments. *(ADR 0042)*
- **Automatic admission is a grant** held by a named automation principal that does not bypass grants. *(ADR 0043)*
- **Tooling signals are advisory** and never change deterministic report fields. *(ADR 0045)*
- **No customer data enters this public repository** — no rule content, thresholds, labelled examples or documents.
  The public demonstration runs on synthetic data.

## Decisions pending

Each is phrased so that the work below can proceed on either answer; tickets branch on them rather than presume them.

| Decision | Options | Recommendation |
|---|---|---|
| Publication of the rules and compliance packages (a public clone of this repository cannot currently build without them) | publish the mechanism / keep private and vendor a stub | publish the mechanism; keep any deployment's rule content private |
| Package names | vendor-branded working names / neutral names aligned to upstream's "evaluate" and "judgments" vocabulary | neutral |
| May automation ever finalise an outcome? | never / asymmetric by family | asymmetric: *supports* only, very high probability, low-consequence families; *contradicts* at any confidence routes to a human, never a silent auto-fail; high-consequence predicates never |
| Data posture for inference, evaluation and fine-tuning | local only / zero-retention hosted / masked corpus | local-first per region; hosted only as an opt-in profile with disclosure and a signed DPA; evaluation sets stay in-region; documents need their own masking decision before any fine-tune |
| Hosted instrument during evaluation | never / synthetic and public data only / any data | synthetic and public data only until contracts exist |
| Who owns thresholds | business owner (DMN) / compliance owner (rule revisions) | DMN as the home, compliance lifecycle as the approval |
| A labelled record-and-replay transport for demos, CI and cold clones | allowed / live only | allowed, labelled "replayed from recording, date, model"; a live-mode job opt-in |
| Erasure versus replay (with ADR 0024) | encrypted state with tombstones and hash-only proofs / no stored state | encrypted state, tombstoned on key destruction |
| Default local model, runtime placement and sizing | `laya` / `decider` / `winnow`; CPU / GPU | decided by the licence audit and spike 0, per region |
| Minimum labelled n per family; evaluation-set ownership and labelling protocol | — | set per family before its first band table |
| Convention for model-derived evidence in OSCAL export | new method / `examine` with a model collector | `examine`, collector naming the model digest, ledger id in custody |
| An emulated profile over chat-model log-probabilities | excluded / separate calibration family | research only; never pooled with native answers |
| Programme scale | broad / one slice first | one slice proves a measured review-time reduction before broad claims enter public docs |

## Package boundaries

| Package | Visibility | Owns | Never does |
|---|---|---|---|
| `ash_ai` (upstream) | public | the evaluate action, answer types, transport via `req_llm` | ledger, calibration, thresholds |
| judgments package (working name `ash_ai_systemone`) | public | question registry DSL; profiles and residency; ledger resource fragments (the host defines the resource on its platform base); cache, replay and shadow; calibration runs; the DMN bridge that flattens answers into inputs; telemetry; tool exposure of judged questions | call a model inside a check, FEEL, rules or a projector; hold thresholds in configuration; store policy |
| evidence package (working name `ash_evidence`) | public, mechanism only | document versions; addressed atoms; lexical and vector retrieval; dual-hypothesis candidates; evidence packets by source id; the assertion → admission flow; bridges to rule facts and evidence artifacts | rule semantics; compliance status; any domain's predicates or wording |
| `ash_decisions` | public | band tables; the publish-time calibration verifier hook | model calls in FEEL |
| `ash_rules` | pending publication | crisp evaluation over facts; the outcome lattice, unchanged | thresholds; probabilities |
| `ash_compliance` | pending publication | the model-derived evidence convention; a fact builder that reads the ledger; `fact_snapshot_hash` covering ledger ids | live model calls on a guard path |
| `ash_bpmn` | public | a standing evaluation process: `ash:call` service task → evaluate action, a human lane for the middle band; struct and dotted-path promotion of answers onto a token | a model as a live gateway oracle |
| `ash_events`, `ash_events_projections` | public | record-don't-recompute; "what did the model say as of X" by time travel | projectors that call models |
| `ash_agent_tools` | public | optional, advisory consumption: a `:model` tier, behavioural-law detectors, semantic `did_you_mean`, rerank, tool-gap triage, laws and judge tools over MCP | change a deterministic verdict |
| this repository | public | wiring, the host ledger resource, the automation principal, residency configuration, doctrine | re-derive library machinery |
| the public teaching demonstration (clinic-demo) | public | all three tracks on synthetic data: clinician credentials and consent forms → "appointment at risk"; a free-text complaint → `Choice` → triage DMN | real data |
| a deployment's private slice | private | its rule library, predicates, question wording, thresholds, labelled evaluation set and masking | anything generic |

## Waves

**W0 — decisions and hygiene (days).** The pending decisions above put to the operator with their recommendations.
Working research documents moved out of the public tree or triaged into `docs/research/`. Stale branches proposed for
pruning.

**W1 — land what is already written (the critical path).** One integrator lane in this repository, because `_build`
and `mix.lock` do not tolerate two. Bump the first-party packages to their mains — which brings in the DMN overlap
verifier and matched-rule recording that band tables depend on, and the process-engine and projection fixes; drop the
forked Ash pin and track hex; depend on `ash_agent_tools` by git rather than a machine-local path; wire the laws judge
into CI; make a cold clone build (per the publication decision); a documentation truth pass over counts and hand-off
notes.

**W2 — foundations, alongside late W1.**
- **Spike 0**, in the public demonstration, with no new packages: `ash_ai` `evaluate` against a local Ollaya and the
  hosted instrument; one `Noul` over appointment notes and one `Choice` feeding a triage DMN; twenty hand-labelled
  items. Measure band separation, latency and cold-load.
- A model licence audit of the local candidates.
- Runtime placement and sizing, per region.
- The judgment-record RFC, designed once together with the agent tooling's existing provenance envelope, in the house
  RFC format (`docs/rfc/`).
- The labelling programme design: owner, data handling, n per family, hard-negative taxonomy.
- Operator review of ADRs 0038–0045.

**W3 — the substrate.** The judgments package 0.1: profiles and residency, the question registry, the ledger with its
replay-safe create, cache, replay and shadow, telemetry. Then calibration storage and the publish-time verifier. Then
the bridges: DMN inputs, rule facts from the ledger, a BPMN-callable wrapper, evidence artifacts. Upstream proposals in
parallel: a vetoable `on_tool_start` and an `Evidence` answer type for `ash_ai`; answer-struct promotion and its crash
fix for `ash_bpmn`.

**W4 — the three tracks in parallel.** Tooling (ADR 0045). Agents in the application. Rules and compliance: the evidence
package first, then a private vertical slice (a supplier's documents checked against a customer's requirements, per
customer, dated, per region) and its public analogue in the demonstration.

**W5 — the demonstration, interleaved.** A replay transport and a local-runtime devenv process after W3; the
"answered by" provenance chip in the experience layer; audience demos alongside W4; the compliance headline after the
evidence mechanism; narrative documentation last.

**W6 — research.** The model as a state-conditioned oracle *in a simulator only*, with fitted parameters as tenant data
under ADR 0029; fine-tuning; distilling reviewer overrides into *proposed* rule revisions through the approval
lifecycle; the emulated profile.

## Entry gates

| Gate | Requires |
|---|---|
| **W3 may start** | W1's dependency bump and git dependency landed; the judgment-record RFC frozen; spike 0's result recorded here, including a negative one |
| **A band table may publish** | the DMN overlap verifier and matched-rule recording in this repository's lock; a calibration run for the family at the model digest named, above the family's minimum n |
| **An automation grant may be issued** | an active band table for the family; the random-audit sample running; an operator decision for that family |
| **A hosted profile may see customer documents** | a signed DPA and a zero-retention contract; ADR 0026's disclosure logging built; the tenant has opted in |
| **Any public claim of benefit** | the one-slice measurement below, with its region and date |

## How it will be measured

- **Spike 0:** separation between the probability distributions of labelled positives and negatives; median and tail
  latency, warm and cold; cold-load time against client timeouts. A spike that shows no usable separation is a result,
  and is written down as one.
- **Per family, per region:** expected calibration error, Brier score, reliability bins, and selective accuracy against
  coverage at each candidate threshold — the conformal selective-prediction framing, with cost-aware deferral.
- **The false-*supports* rate** on randomly audited automatic admissions, reported separately from every other error,
  because it is the one that manufactures compliance.
- **The headline:** reviewer time per decision at a fixed error rate, on one slice, against the same slice without
  System One. The claim is judged on this number before any broader one is made.
- **Evidence recall:** the audit sweep's full rule × atom matrix against production retrieval; evidence the sweep
  finds and retrieval misses is a retrieval defect.
- **Wire drift:** the contract test against both instruments, run in CI.
- **Tooling:** review-tier hits resolved per adjudication, and the rate at which advisory signals are overruled — with
  deterministic report fields unchanged, byte for byte.

Every number carries its region, its model digest and its date. None of the vendor's published accuracy figures is used
as a planning threshold.

## Known risks

- **The vendor is new.** Public for twelve days when this was written; self-reported claims; no public DPA or SLA. The
  hedge is local-first and a contract test, not a contract.
- **The local instrument is small.** A 1,024-token context for the default router model forces decomposition and
  context growth; some whole-document questions are unavailable locally.
- **The compatibility layer has no owner in common.** Ollaya is independent of the vendor; wire compatibility can drift
  on either side.
- **Selection bias.** Reviewed data is the middle band. Random audit sampling is mandatory, not optional.
- **Labelling is the cost.** Every family needs labelled data before it can automate anything; that, not inference, is
  the programme's expense.
- **Reviewer-facing surfaces must ship with their translations**, for every language a deployment supports; nothing in
  the existing doctrine tracks that yet ([thesis 7 §7](../manifesto/07-what-we-do-not-have.md#7-internationalization)).
