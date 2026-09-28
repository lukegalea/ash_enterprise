# System One: design and execution plan

Status: **proposed — nothing is built.** Doctrine drafted (thesis 8, ADRs 0038–0047, all `proposed`); no package,
resource or call site exists. The first wave is landing work that is already written elsewhere, not new building.
*Amended 2026-09-28:* the operator's decisions are recorded, the data posture is zone-first, and a private shadow slice
on real documents moves into W2. *Amended 2026-09-28 (operator answers):* the hosted model is never an instrument;
a zone declares the residency restrictions it cannot satisfy and admits data only under an admissible tag; the
activating person is the author of record for anything learned.
Related: [thesis 8](../manifesto/08-models-observe-declarations-decide.md), ADR 0026, ADR 0028, ADR 0029, ADR 0035,
ADRs 0038–0047, [`ash-rules-and-compliance.md`](ash-rules-and-compliance.md).

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
  provider, which is how this platform calls an in-zone Ollaya; the answer types are upstream's. This plan writes no
  HTTP client, provider behaviour or answer type. New generic answer kinds (`Evidence`) and hooks (a vetoable
  `on_tool_start`) are proposed upstream. *(ADR 0039)*
- **Never in a check, never a grant, never in FEEL, rules or projectors.** *(ADR 0038)*
- **Questions are declarations**, content-hashed; the hash is the ledger identity. *(ADR 0039)*
- **The ledger is a host resource on the platform base**, created by a replay-safe action that accepts the answer as
  input; cache, replay and shadow modes; the model digest is part of the verdict's identity; no floating aliases on
  admission paths. *(ADR 0040)*
- **Thresholds are DMN band tables**, published only with a supporting calibration run and activated through the
  approval lifecycle; probabilities stop at the band table. *(ADR 0041)*
- **Zone-first.** A zone is a declared record with a jurisdiction, a classification ceiling and the residency
  restrictions it cannot satisfy; data enters a zone only if its residency tag is admissible there, and data restricted
  to another jurisdiction never enters; every profile and store names its zone; every instrument runs in a zone —
  decision models served by Ollaya and in-zone generative runtimes, never a hosted model; any flow out of a zone is a
  disclosure with a recorded authorization; per-jurisdiction stacks and masking are deferred, each with a named
  trigger; the contract test pins Ollaya and the wire specification. *(ADR 0042)*
- **Automatic admission is a grant** held by a named automation principal that does not bypass grants. *(ADR 0043)*
- **Tooling signals are advisory** and never change deterministic report fields. *(ADR 0045)*
- **The declaration is the output contract.** Every model output shape — System One options, generative JSON Schema,
  tool input, MCP `outputSchema` — derives from Ash types and constraints through one mapping, never from typespecs or
  Dialyzer; decode-time where the runtime can, the Ash cast always; schema-valid is not correct. *(ADR 0046)*
- **Learning produces proposals.** Optimisers, distillation, rule mining, fine-tunes and simulation fits write proposal
  records with lineage; nothing learned is applied in serving; adoption is an approval and re-earns calibration on data
  the learner never saw; the person who activates is the author of record, whoever or whatever drafted it.
  *(ADR 0047)*
- **The inference pipeline is a separate subsystem that consumes declarations.** It does not amend thesis 1's premise
  that the application is derived from what is declared. *(ADR 0038, thesis 8)*
- **No customer data enters this public repository** — no rule content, thresholds, labelled examples or documents.
  The public demonstration runs on synthetic data.

## Decisions taken (2026-09-28)

The operator decided the open questions on 2026-09-28. Every recommendation was taken except the data posture, which
became zone-first.

| Decision | Taken |
|---|---|
| Publication of the rules and compliance packages (a public clone of this repository cannot currently build without them) | Publish the mechanism; keep any deployment's rule content private. Approved; a full-history scan found nothing that must stay private, and the publication itself is pending the operator's own step |
| Package names | Neutral: the judgments package is `ash_judgments` (formerly the working name `ash_ai_systemone`), the evidence package `ash_evidence` |
| May automation ever finalise an outcome? | Asymmetric: *supports* only, very high probability, low-consequence families; *contradicts* at any confidence routes to a human, never a silent auto-fail; high-consequence predicates never |
| Data posture for inference, evaluation and fine-tuning | **Zone-first**: an operator-declared zone processes customer data unmasked; leaving a zone is a disclosure; per-jurisdiction stacks and masking are deferred with triggers ([ADR 0042](../adr/0042-in-zone-inference-leaving-the-zone-is-a-disclosure.md)) |
| Hosted instrument | **Never** — there is no access to it. The only instruments are decision models served by Ollaya in the zone and in-zone generative runtimes; the wire specification is kept |
| Residency in a zone | A zone declares its jurisdiction and the residency restrictions it cannot satisfy; data restricted to the zone's own jurisdiction is admissible, data restricted to another never enters; processing outside production is not, by itself, restricted ([ADR 0042](../adr/0042-in-zone-inference-leaving-the-zone-is-a-disclosure.md)) |
| Authorship of learned artefacts | The person who activates a proposed rule bundle, band table or question revision is its author of record, which satisfies ADR 0028's business-authored requirement ([ADR 0047](../adr/0047-learning-produces-proposals.md)) |
| Coding agents in the pipeline | Sessions carry attribution (commit trailers, tracker comments) and are excluded from the programme's cost tracking for now |
| Who owns thresholds | DMN as the home, compliance lifecycle as the approval |
| A labelled record-and-replay transport for demos, CI and cold clones | Allowed, labelled "replayed from recording, date, model"; a live-mode job opt-in |
| Programme scale | One slice proves a measured review-time reduction before broad claims enter public docs |

Still pending, and marked so in the records that carry them:

- erasure versus replay, decided together with ADR 0024 (the recommendation remains encrypted state, tombstoned on key
  destruction);
- the default local model, after the licence audit and spike 0;
- the minimum labelled n per family, including the optimise split, and evaluation-set ownership and labelling protocol;
- the convention for model-derived evidence in OSCAL export (recommendation: `examine`, a collector naming the model
  digest, the ledger id in custody);
- an emulated profile over an in-zone generative runtime's log-probabilities (recommendation: research only, never
  pooled with native answers).

## Package boundaries

| Package | Visibility | Owns | Never does |
|---|---|---|---|
| `ash_ai` (upstream) | public | the evaluate action, answer types, transport via `req_llm`; prompt output schemas derived from Ash types (exists). Proposed upstream: a string-keyed, refinement-complete schema from one mapping, per-call output constraints, MCP `outputSchema` | ledger, calibration, thresholds |
| `req_llm` (upstream) | public | transport; per-provider schema sanitisers. Proposed upstream: string-key normalisation before sanitising | define schemas |
| `ash_judgments` (formerly the working name `ash_ai_systemone`) | public | question registry DSL; profiles and zones; ledger resource fragments (the host defines the resource on its platform base); cache, replay and shadow; calibration runs; question lineage and revision-proposal records; the DMN bridge that flattens answers into inputs; telemetry; tool exposure of judged questions | call a model inside a check, FEEL, rules or a projector; hold thresholds in configuration; store policy; apply a learned artefact in serving |
| `ash_evidence` | public, mechanism only | document versions; addressed atoms; lexical and vector retrieval; dual-hypothesis candidates; evidence packets by source id; the assertion → admission flow; bridges to rule facts and evidence artifacts | rule semantics; compliance status; any domain's predicates or wording |
| `ash_decisions` | public | band tables; the publish-time calibration verifier hook | model calls in FEEL |
| `ash_rules` | publication approved, pending the operator's step | crisp evaluation over facts; the outcome lattice, unchanged | thresholds; probabilities |
| `ash_compliance` | publication approved, pending the operator's step | the model-derived evidence convention; a fact builder that reads the ledger; `fact_snapshot_hash` covering ledger ids | live model calls on a guard path |
| `ash_bpmn` | public | a standing evaluation process: `ash:call` service task → evaluate action, a human lane for the middle band; struct and dotted-path promotion of answers onto a token | a model as a live gateway oracle |
| `ash_events`, `ash_events_projections` | public | record-don't-recompute; "what did the model say as of X" by time travel | projectors that call models |
| `ash_agent_tools` | public | optional, advisory consumption: a `:model` tier, behavioural-law detectors, semantic `did_you_mean`, rerank, tool-gap triage, laws and judge tools over MCP; `mix ash_agent.contracts` (declared versus inferred generic-action returns, advisory); return constraints in `describe` | change a deterministic verdict |
| an optimiser library (`imp`, third-party) | optional; development, test or a research application only | nothing of ours: it proposes question wordings through ADR 0047 | a runtime dependency; an authoring surface; a gate; code-executing retrieval over evidence |
| in-zone runtimes (infrastructure, not packages) | per zone | a pinned decision runtime; a grammar-capable generative runtime; a document parser; embedding and reranking models; Postgres | run outside the zone that holds the data they read |
| this repository | public | wiring, the host ledger resource, the automation principal, zone and profile configuration, a development and test guard that casts generic-action returns on the platform base, doctrine | re-derive library machinery |
| the public teaching demonstration (clinic-demo) | public | all three tracks on synthetic data: clinician credentials and consent forms → "appointment at risk"; a free-text complaint → `Choice` → triage DMN | real data |
| a deployment's private slice | private, in its zone | its rule library, predicates, question wording, thresholds, labelled evaluation set, the shadow-slice harness and its fixtures | anything generic |

## Waves

**W0 — decisions and hygiene (days).** The decisions above, taken on 2026-09-28. The zone declaration recorded as data:
jurisdiction, ceiling, the residency restrictions it cannot satisfy, members, controls, access list, and the rule that
development-agent sessions are out-of-zone consumers; every dataset exported into the zone tagged with its residency
restriction before it enters. Working research documents moved out of the public tree or triaged into `docs/research/`.
Stale branches proposed for pruning.

**W1 — land what is already written (the critical path).** One integrator lane in this repository, because `_build`
and `mix.lock` do not tolerate two. Bump the first-party packages to their mains — which brings in the DMN overlap
verifier and matched-rule recording that band tables depend on, and the process-engine and projection fixes; drop the
forked Ash pin and track hex; depend on `ash_agent_tools` by git rather than a machine-local path; wire the laws judge
into CI; make a cold clone build (per the publication decision); a documentation truth pass over counts and hand-off
notes.

**W2 — foundations, alongside late W1.**
- **Spike 0**, in the public demonstration, with no new packages: `ash_ai` `evaluate` against a pinned local Ollaya; one
  `Noul` over appointment notes and one `Choice` feeding a triage DMN; twenty hand-labelled items. Measure band
  separation, latency and cold-load.
- **A private shadow slice on real documents, inside a declared zone, with no new packages**: parse to atoms,
  constrained local extraction, deterministic checks, System One verification, and comparison with the recorded human
  outcome, over a few hundred documents from one jurisdiction; then a timed review study, packet-assisted against the
  current process. It admits nothing. Its result is labelled indicative, with its n, jurisdiction and date.
- **An extract → verify spike on synthetic data in the public demonstration**, the public analogue of the above.
- A seed labelled set for the slice, blind, partly double-labelled, split four ways including an *optimise* split.
- A model licence audit of the local candidates.
- Runtime placement and sizing per zone, recorded with the zone; pinned versions and digests from the first run.
- The judgment-record RFC, designed once together with the agent tooling's existing provenance envelope, in the house
  RFC format (`docs/rfc/`).
- The labelling programme design: owner, data handling, n per family, hard-negative taxonomy.
- Operator review of ADRs 0038–0047.

**W3 — the substrate.** `ash_judgments` 0.1: profiles and zones, the question registry with lineage fields, the ledger
with its replay-safe create, cache, replay and shadow, telemetry. Then calibration storage and the publish-time
verifier. Then the bridges: DMN inputs, rule facts from the ledger, a BPMN-callable wrapper, evidence artifacts.
Upstream proposals in parallel: a vetoable `on_tool_start` and an `Evidence` answer type for `ash_ai`; answer-struct
promotion and its crash fix for `ash_bpmn`; the output-schema, per-call-constraint and MCP `outputSchema` proposals for
`ash_ai` and the sanitiser fix for `req_llm` (ADR 0046). An optimiser spike over one `Choice` family, proposals only
(ADR 0047).

**W4 — the three tracks in parallel.** Tooling (ADR 0045). Agents in the application. Rules and compliance: the evidence
package first, then the package-based private slice (a supplier's documents checked against a customer's requirements,
per customer, dated, in its zone, in shadow) built on the W2 shadow slice, and its public analogue in the
demonstration. Per-jurisdiction production waits for its trigger (ADR 0042).

**W5 — the demonstration, interleaved.** A replay transport and a local-runtime devenv process after W3; the
"answered by" provenance chip in the experience layer; audience demos alongside W4; the compliance headline after the
evidence mechanism; narrative documentation last.

**W6 — research, under ADR 0047.** The model as a state-conditioned oracle *in a simulator only*, with fitted
parameters as tenant data under ADR 0029; fine-tuning; distilling reviewer overrides into *proposed* rule revisions
through the approval lifecycle; the emulated profile. Every output is a proposal record.

## Entry gates

| Gate | Requires |
|---|---|
| **W3 may start** | W1's dependency bump and git dependency landed; the judgment-record RFC frozen; spike 0's result and the private shadow slice's result recorded, including a negative one |
| **A band table may publish** | the DMN overlap verifier and matched-rule recording in this repository's lock; a calibration run for the family at the model digest named, above the family's minimum n |
| **An automation grant may be issued** | an active band table for the family; the random-audit sample running; an operator decision for that family |
| **Data may enter a zone** | its residency tag is admissible there (ADR 0042); untagged data waits |
| **Customer-confidential data may leave a zone** | a recorded authorization (the tenant's opt-in); ADR 0026's disclosure logging built; where the target is a vendor, a signed DPA and zero retention; masking decided (ADR 0042's trigger table) |
| **An optimiser-proposed question version may activate** | a calibration run on splits disjoint from its optimise split; a shadow evaluation; an approval (ADR 0047) |
| **Any public claim of benefit** | the one-slice measurement below, with its jurisdiction and date |

## How it will be measured

- **Spike 0:** separation between the probability distributions of labelled positives and negatives; median and tail
  latency, warm and cold; cold-load time against client timeouts. A spike that shows no usable separation is a result,
  and is written down as one.
- **Per family, per jurisdiction:** expected calibration error, Brier score, reliability bins, and selective accuracy
  against coverage at each candidate threshold — the conformal selective-prediction framing, with cost-aware deferral.
- **The false-*supports* rate** on randomly audited automatic admissions, reported separately from every other error,
  because it is the one that manufactures compliance.
- **The headline:** reviewer time per decision at a fixed error rate, on one slice, against the same slice without
  System One. The claim is judged on this number before any broader one is made.
- **Evidence recall:** the audit sweep's full rule × atom matrix against production retrieval; evidence the sweep
  finds and retrieval misses is a retrieval defect.
- **Wire drift:** the contract test against a pinned Ollaya and the wire specification, run in CI.
- **Egress:** the disclosure log empty for customer-confidential data, per zone.
- **Generative extraction:** the Ash cast-failure rate, and the rate at which System One verification agrees with the
  proposed value.
- **Tooling:** review-tier hits resolved per adjudication, and the rate at which advisory signals are overruled — with
  deterministic report fields unchanged, byte for byte.

Every number carries its jurisdiction, its model digest and its date. None of the vendor's published accuracy figures is
used as a planning threshold.

## Known risks

- **The protocol's vendor is new.** Public for twelve days when this was written; self-reported claims; no public DPA
  or SLA. There is no access to its hosted model and none is used; the dependency is its wire specification, through
  an independent in-zone runtime, watched by a contract test.
- **The local instrument is small.** A 1,024-token context for the default router model forces decomposition and
  context growth; some whole-document questions are unavailable locally.
- **The compatibility layer has no owner in common.** Ollaya is independent of the vendor; wire compatibility can drift
  on either side.
- **The optimiser dependency is experimental** and was one day old on Hex when adopted for research; it never runs in
  serving, which is what makes that acceptable.
- **The local runtime ships several releases a day**, and one added a silent CPU fallback. Pin it, record its version
  on every row, and check that the intended hardware ran.
- **Hosted coding agents are an egress path.** A development agent that reads customer content sends it to its model
  vendor; the zone rule cannot see that path, so it is closed by a restricted database role and by acceptance checks on
  every real-data work item (ADR 0042).
- **Constrained decoding produces valid but wrong answers.** Shape is guaranteed; truth is not. Every generative value
  is verified before it can be admitted.
- **Selection bias.** Reviewed data is the middle band. Random audit sampling is mandatory, not optional.
- **Labelling is the cost.** Every family needs labelled data before it can automate anything; that, not inference, is
  the programme's expense.
- **Reviewer-facing surfaces must ship with their translations**, for every language a deployment supports; nothing in
  the existing doctrine tracks that yet ([thesis 7 §7](../manifesto/07-what-we-do-not-have.md#7-internationalization)).
