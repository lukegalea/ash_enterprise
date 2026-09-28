# ADR 0042 — In-zone inference; leaving the zone is a disclosure

- **Status:** proposed
- **Date:** 2026-09-27
- **Amended:** 2026-09-28 — rewritten zone-first. The residency binary becomes a declared zone with a jurisdiction and
  a classification ceiling; per-jurisdiction stacks, masking and hosted use are deferred, each with a named trigger;
  development agents are counted as consumers; local model facts corrected. Formerly titled "Local-first inference;
  hosted inference is a disclosure".
- **Amended 2026-09-28 (operator answers):** the hosted model is never an instrument (there is no access to it) — the
  only instruments are decision models served by Ollaya in the zone and in-zone generative runtimes; the contract test
  pins Ollaya and the wire specification; a zone declares the residency restrictions it cannot satisfy, and data
  admission into a zone is checked against each item's residency tag; processing outside production is not itself
  restricted; the hosted-model deferrals are removed.

## Context

The question-and-answer surface ([ADR 0039](0039-judgments-are-declared-questions.md)) is the same whichever
instrument answers it. Where the instrument runs — and where the data it reads is allowed to go — is a separate
decision, and it is the one a security questionnaire asks about.

The facts, verified on 2026-09-27 and 2026-09-28:

- **The protocol's vendor, and why the design is local-first.** TypeSafe AI emerged from stealth on 2026-09-15 with a
  $40M seed round — **twelve days** before this record. Its hosted model is text-only and is also reachable through
  OpenRouter and Cloudflare Workers AI, each of which adds its own data policy. Zero data retention is an enterprise
  contract, not the default. No public data-processing agreement, SLA or self-hosted option was found. Its performance
  claims are self-reported. Those facts are why inference was designed local-first. This programme has **no access**
  to the hosted model, so it is not an instrument here at all; what remains of the vendor is its wire specification,
  which Ollaya implements and `req_llm`'s `typesafe` provider speaks.
- **Local decision runtime.** Ollaya is an independent, Apache-2.0 runtime for decision models that **explicitly
  disclaims affiliation** with the vendor. Its binary is `ollaya` (not `ol`, as some earlier notes have it); it serves
  on port 11435; it is wire-compatible with the vendor's Python SDK 0.7.1 at the API level, **not** at the level of
  output parity. It runs models on ONNX Runtime and llama.cpp, on CPU everywhere and on NVIDIA GPUs (Linux, and Windows
  from v0.7). It serves decision models only — **it has no generative endpoint**. A first request can take longer than
  ten seconds while a model loads, which trips default client timeouts. It exposes an MCP server (`ollaya mcp`). It
  shipped five releases in two days (v0.6.1 to v0.7.3), and one of them added a *silent* CPU fallback for unsupported
  GPUs — so a pinned version and a check that the intended hardware actually ran are both necessary.
- **Local models are small, and their sizes decide what runs where.** `laya:typed-decisions` (421M parameters,
  Apache-2.0) has a **1,024-token** context. `winnow:e4b`, which Ollaya now recommends as the default, is a Q8_0 GGUF
  needing about **9 GB** of VRAM with an 8k context, so it fits a single 11 GB consumer GPU. `decider` (built on
  Qwen3.5, 0.8b–4b; it reads next-token logits for option letters) has a 32k context but needs about **13–14 GB** of
  VRAM at every published size, so it does *not* fit that card. A 9B-class instruct model at 4-bit quantisation (under
  6 GB) fits for constrained extraction, but not alongside `winnow:e4b` on the same 11 GB card, so a zone is simplest
  with one host per role — decision models on one, the generative model on another.
  Bundled models retain their own licences — a mix of Apache-2.0, MIT and proprietary — which have not yet been
  audited for this use.
- **Local generative runtimes exist and are typed.** llama.cpp's server, Ollama and vLLM decode under a grammar
  compiled from a JSON Schema, and `req_llm` already reaches them
  ([ADR 0046](0046-the-declaration-is-the-output-contract.md)). The whole pipeline, generative rung included, can
  therefore run on hardware an operator controls.
- **The transport is the wire specification.** `req_llm`'s `typesafe` provider takes a per-call `base_url`, so an
  evaluate action reaches an in-zone Ollaya by profile; nothing on the call path depends on the vendor's service.
- **[ADR 0026](0026-ai-governance-is-disclosure.md)** (proposed) treats a model call as an outbound disclosure to a
  sub-processor: log prompt and response under the tenant and correlation id, record vendor and version, and enforce a
  per-tenant opt-out next to the client.
- **Jurisdiction is already a boundary.** A deployment that runs separate regional stacks must keep every observation,
  cache entry, evaluation set and metric within the region it came from; a total that silently covers one region is the
  commonest way such numbers go wrong.
- **Some data carries a residency restriction.** Content can be contractually restricted to one country. A zone in any
  other jurisdiction cannot hold that content at all, whatever its classification ceiling; content restricted to the
  zone's own jurisdiction it can.
- **A development agent is a consumer.** A hosted coding agent that reads a document, prints a parse, or queries a
  database through a development tool sends what it read to its model vendor. So does any sub-agent it starts.

The earlier draft of this record answered with a per-region residency binary, and made masking and hosted contracts
preconditions of any real-data work. That put the most expensive controls first and the demonstration of value last.
The posture below keeps the same boundary and states it as data, so that a deployment can start inside one declared
zone and add the rest when a named condition makes it necessary.

## Decision

**A zone is a declared, recorded boundary with a jurisdiction, a classification ceiling and a list of the residency
restrictions it cannot satisfy. Every profile and every store names its zone. Data enters a zone only if its residency
tag is admissible there. Inference runs in the zone; every instrument is in a zone; any flow out of a zone is a
disclosure.**

- **`Zone`** — id, jurisdiction, classification ceiling, **inadmissible residency restrictions**, `declared_by`,
  `declared_at`, `review_by`, basis, and the controls the declaration relies on (access list, storage, deletion path,
  no copies outside the zone).
- **Data classes and residency tags** on every document version, dataset, evaluation set and ledger row: a class —
  `public`, `synthetic`, `internal`, `customer_confidential` — and a residency restriction: none, or the jurisdiction
  the data is restricted to.
- **The admission rule**, enforced on the ingest path where data is first written into a store in the zone: data may
  enter zone *Z* iff its class is at or below `Z.ceiling`, its residency restriction is none or is satisfied by
  `Z.jurisdiction` (the zone lies inside the jurisdiction the data is restricted to), and the restriction is not among
  `Z.inadmissible_restrictions`. Data under a restriction the zone cannot satisfy — content
  contractually restricted to another country, for example — **never enters the zone**: not as a document, a dataset
  row, an evaluation item, a cache entry or the state of a ledger row. Admission is checked against the data's own
  tag, not inferred from where it came from or only at egress; a record whose restriction is not yet known is refused
  until it is tagged.
- **The flow rule**, enforced in the profile resolver next to the client: data of class *C* in zone *Z* may flow to a
  target *T* iff `T.zone == Z` and `C ≤ Z.ceiling`. Any other flow is a disclosure event, allowed only with a recorded
  authorization — a per-tenant opt-in for customer-confidential data, an operator acknowledgement for internal data,
  nothing for public or synthetic — and logged under ADR 0026 (vendor, model version, tenant, correlation id, bytes,
  class).
- **Outside production is not, by itself, restricted.** A zone need not be a production environment. Processing
  customer data in a zone outside production is permitted by this record; what governs it is the zone declaration, the
  admission rule and the flow rule, not the name of the environment.
- **Inside a zone, no masking.** Data at or below the ceiling is processed as it is. Masking is a control for data
  leaving a zone, not a substitute for the boundary.
- **A regional stack is a zone whose jurisdiction is that region.** `:in_cluster` now reads as "same zone as the data";
  `:sub_processor` as "outside every declared zone". The binary survives as a derived value.
- **Consumers count.** A development agent, notebook or query tool that sends what it reads to a hosted model is an
  out-of-zone target like any other.
- **Jurisdiction is a dimension of everything.** Every ledger row, cache key, calibration run and metric carries its
  zone and therefore its jurisdiction, and the residency tag of the data it was computed from. A calibration run in one
  jurisdiction does not license a band table in another. There is no cross-jurisdiction total without the jurisdiction
  shown.
- **Start with one zone and one jurisdiction.** Data from elsewhere enters only if its residency tag is admissible,
  and its metrics stay separated by the jurisdiction it came from.

| | Same zone as the data | Outside every declared zone (a gateway, a hosted agent, any hosted model) |
|---|---|---|
| Default | **yes** | no |
| May be an instrument | decision models served by Ollaya; in-zone generative runtimes (llama.cpp, Ollama, vLLM) | **never** |
| ADR 0026 treatment | recorded in the ledger; not an outbound disclosure | outbound disclosure: vendor, model version, gateway, tenant, correlation id, bytes, class |
| Authorization | the zone declaration | recorded per flow: per-tenant opt-in (customer-confidential), operator acknowledgement (internal), none (public, synthetic) |
| Contract prerequisite | model licence audit | for customer-confidential data to a vendor: a signed DPA and zero retention |
| May feed an admitted fact | yes, with a pinned digest | no — nothing outside a zone is an instrument |

**The flow check lives next to the client; the admission check lives on the ingest path.** The flow rule is enforced in
the profile resolver, where the call is made, and the admission rule where data is first written into the zone — not in
a policy check (which must not query) and not in the UI (which is not the only caller). A zone declaration is an
operator's authority for the deployment it covers; it is not a statement about what any customer agreement permits,
and no document should present it as one.

**Contract tests pin Ollaya and the wire specification.** CI carries a contract test — a fixed set of questions and
states, on synthetic data only — run against a pinned local Ollaya through the `req_llm` `typesafe` provider this
platform calls it with, and checked against the wire specification at the SDK compatibility version Ollaya declares.
Its job is to detect wire drift between the runtime and the client, which are maintained by parties with no agreement
between them. It is not an accuracy test; accuracy is calibration's job
([ADR 0041](0041-thresholds-are-dmn-earned-by-calibration.md)).

**Vendor risk, tiered per [thesis 6](../manifesto/06-reversibility.md).** `ash_ai` stays tier 2. The judgments package,
`ash_judgments`, is tier 3 — first-party, 0.x, confined to its own directory and one host domain. The in-zone
runtimes — Ollaya and the generative runtime — are services behind a network boundary (thesis 6's fourth category),
and both clear its two rules: neither holds an authorization model of its own, and removing either degrades triage
rather than breaking the application. There is no hosted instrument to tier. The hedge against a twelve-day-old
protocol vendor is structural rather than contractual: the programme depends on its wire specification only, through an
independent runtime, and never on its service.

**Deferred, each with its trigger.** Each item returns when its trigger fires, not before; the triggers are reviewed on
a schedule and recorded with the zone.

| Deferred item | Trigger that brings it back |
|---|---|
| Separate stacks per jurisdiction | Data under a residency restriction no declared zone can satisfy, any customer-visible output (leaving shadow mode), or moving the pipeline into a production environment outside the zone |
| Document masking | Any egress of customer-confidential text: outside labellers, hosted training, or any public artefact |
| Encryption of the ledger's `state` ([ADR 0040](0040-record-dont-recompute.md)) | The first store outside the zone, or the first multi-user access to the zone |
| More inference capacity in the zone | Batch runtime for an evaluation set exceeds its window, or a needed model does not fit the zone's hardware |
| A formal security and legal approval record | Before any output is customer-visible, or before any customer-confidential data leaves a zone |

**Pending, and marked so:**

- where the runtime is placed and sized in each zone — an operational record kept with the zone, not doctrine — and
  the cold-start budget;
- the default local model (`laya`, `winnow` or another), after the licence audit and a measured spike;
- whether an *emulated* profile — typed decisions extracted from an in-zone generative runtime's log-probabilities —
  is admitted at all.
  If it is, it is a separate calibration family, never pooled with native System One answers.

## Does it consume ActorContext?

**Not directly, and it cannot — the same shape as ADR 0026.** Inbound, the evaluate action runs as the requesting actor,
so the state reaching any instrument is what that actor could already read. Outbound, no in-zone runtime can evaluate
a grant, and none is asked to: they hold no permission model to synchronize, which is precisely why they pass thesis
6's first rule. The zone's admission and flow rules and the per-tenant opt-in are configuration read by the ingest path
and the client, deliberately outside the policy layer.

## Consequences

**What this makes easy.** The questionnaire sentence "no customer data leaves its declared zone for inference, and the
egress log proves it" is true by construction and checkable from the ledger. An empty egress log for
customer-confidential data is the demonstrable privacy claim, and a refusal on the ingest path makes "restricted data
never entered this zone" checkable too. Real documents can be processed from the first week, inside the zone, without
first building masking. The protocol vendor's failure, repricing or changed retention policy costs nothing
operational: what the platform depends on is a wire specification an independent runtime implements.

**What it makes hard.** Someone has to run, size, patch, pin and monitor an inference runtime in every zone, including
checking that it ran on the hardware intended. Local decision models are small — 1,024 tokens for the default router
model — and there is no larger hosted model to fall back on, so questions have to be decomposed, and some whole-document
questions are unavailable. The larger decision model does not fit a single consumer GPU. Every ingest path has to carry
a residency tag, and data whose restriction is unknown waits until someone tags it. Local accuracy is unmeasured on our
questions until the spike runs. The deferred items are real work waiting on triggers, and someone has to watch the
triggers.

**Our own development agents are outside the zone.** The agents that build and operate this system are typically hosted
models, so a development agent reading customer content sends it to its model vendor. The zone rule, enforced in the
profile resolver, cannot see that path. It is closed by role and by practice instead, and this record says so rather
than claiming more:

- agent sessions use a database role that cannot read customer text columns, and development query tools are never
  pointed at a store in the zone that holds customer data;
- agents work on code, schemas, synthetic fixtures and aggregate metrics computed inside the zone — counts, rates,
  confusion matrices — never on raw customer text;
- every work item that touches real data carries an acceptance check that no customer-confidential content appears in
  agent transcripts, trackers, commits or public repositories.

**What it forecloses.** Any hosted instrument. Restricted data entering a zone that cannot satisfy its restriction.
Silent routing of a tenant's data to a gateway. A single global evaluation set or metric. Treating masking inside the
zone as a privacy control, or an operator's declaration as customer consent.

## Reversal

Zones and profiles are configuration resolved by one function. Splitting into per-jurisdiction stacks is declaring more
zones and moving stores, which the jurisdiction dimension already anticipates. Admitting a hosted instrument at all
would take a superseding record, access this programme does not have, and the disclosure and contract work ADR 0026
describes; the change to the resolver would be the smallest part. Relaxing the admission rule is a change to the zone
declaration, recorded like the declaration itself. Dropping the local runtime is removing a process from the zone and a
profile from configuration; the ledger keeps every answer it already recorded.
