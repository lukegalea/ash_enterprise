# ADR 0042 — In-zone inference; leaving the zone is a disclosure

- **Status:** proposed
- **Date:** 2026-09-27
- **Amended:** 2026-09-28 — rewritten zone-first. The residency binary becomes a declared zone with a jurisdiction and
  a classification ceiling; per-jurisdiction stacks, masking and hosted use are deferred, each with a named trigger;
  development agents are counted as consumers; local model facts corrected. Formerly titled "Local-first inference;
  hosted inference is a disclosure".

## Context

The question-and-answer surface ([ADR 0039](0039-judgments-are-declared-questions.md)) is the same whichever
instrument answers it. Where the instrument runs — and where the data it reads is allowed to go — is a separate
decision, and it is the one a security questionnaire asks about.

The facts, verified on 2026-09-27 and 2026-09-28:

- **Hosted.** TypeSafe AI emerged from stealth on 2026-09-15 with a $40M seed round — **twelve days** before this
  record. Its model, Jev, is text-only; its request context is 64k tokens (32k for the state); `jev-1.13.0` is pinnable
  and the `-latest` and `-preview` aliases move. Input is priced at $0.042 per million tokens. It is also reachable
  through OpenRouter and Cloudflare Workers AI, each of which adds its own data policy. Zero data retention is an
  enterprise contract, not the default. No public data-processing agreement, SLA or self-hosted option was found. Its
  performance claims are self-reported.
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
  6 GB) fits for constrained extraction, but not alongside `winnow:e4b` on the same 11 GB card; the two take turns.
  Bundled models retain their own licences — a mix of Apache-2.0, MIT and proprietary — which have not yet been
  audited for this use.
- **Local generative runtimes exist and are typed.** llama.cpp's server, Ollama and vLLM decode under a grammar
  compiled from a JSON Schema, and `req_llm` already reaches them
  ([ADR 0046](0046-the-declaration-is-the-output-contract.md)). The whole pipeline, generative rung included, can
  therefore run on hardware an operator controls.
- **The transport is indifferent.** `req_llm`'s `typesafe` provider takes a per-call `base_url`, so the same evaluate
  action reaches either instrument by profile.
- **[ADR 0026](0026-ai-governance-is-disclosure.md)** (proposed) treats a model call as an outbound disclosure to a
  sub-processor: log prompt and response under the tenant and correlation id, record vendor and version, and enforce a
  per-tenant opt-out next to the client.
- **Jurisdiction is already a boundary.** A deployment that runs separate regional stacks must keep every observation,
  cache entry, evaluation set and metric within the region it came from; a total that silently covers one region is the
  commonest way such numbers go wrong.
- **A development agent is a consumer.** A hosted coding agent that reads a document, prints a parse, or queries a
  database through a development tool sends what it read to its model vendor. So does any sub-agent it starts.

The earlier draft of this record answered with a per-region residency binary, and made masking and hosted contracts
preconditions of any real-data work. That put the most expensive controls first and the demonstration of value last.
The posture below keeps the same boundary and states it as data, so that a deployment can start inside one declared
zone and add the rest when a named condition makes it necessary.

## Decision

**A zone is a declared, recorded boundary with a jurisdiction and a classification ceiling. Every profile and every
store names its zone. Inference runs in the data's zone by default; any flow out of a zone is a disclosure.**

- **`Zone`** — id, jurisdiction, classification ceiling, `declared_by`, `declared_at`, `review_by`, basis, and the
  controls the declaration relies on (access list, storage, deletion path, no copies outside the zone).
- **Data classes** on every document version, dataset, evaluation set and ledger row: `public`, `synthetic`,
  `internal`, `customer_confidential`.
- **The one rule**, enforced in the profile resolver next to the client: data of class *C* in zone *Z* may flow to a
  target *T* iff `T.zone == Z` and `C ≤ Z.ceiling`. Any other flow is a disclosure event, allowed only with a recorded
  authorization — a per-tenant opt-in for customer-confidential data, an operator acknowledgement for internal data,
  nothing for public or synthetic — and logged under ADR 0026 (vendor, model version, tenant, correlation id, bytes,
  class).
- **Inside a zone, no masking.** Data at or below the ceiling is processed as it is. Masking is a control for data
  leaving a zone, not a substitute for the boundary.
- **A regional stack is a zone whose jurisdiction is that region.** `:in_cluster` now reads as "same zone as the data";
  `:sub_processor` as "outside every declared zone". The binary survives as a derived value.
- **Consumers count.** A development agent, notebook or query tool that sends what it reads to a hosted model is an
  out-of-zone target like any other.
- **Jurisdiction is a dimension of everything.** Every ledger row, cache key, calibration run and metric carries its
  zone and therefore its jurisdiction. A calibration run in one jurisdiction does not license a band table in another.
  There is no cross-jurisdiction total without the jurisdiction shown.
- **Start with one zone and one jurisdiction.** Data from a second jurisdiction is either a single recorded exception
  or waits for its trigger below.

| | Same zone as the data | Outside every declared zone (hosted Jev, a gateway, a hosted agent) |
|---|---|---|
| Default | **yes** | no |
| ADR 0026 treatment | recorded in the ledger; not an outbound disclosure | outbound disclosure: vendor, model version, gateway, tenant, correlation id, bytes, class |
| Authorization | the zone declaration | recorded per flow: per-tenant opt-in (customer-confidential), operator acknowledgement (internal), none (public, synthetic) |
| Contract prerequisite | model licence audit | for customer-confidential data to a vendor: a signed DPA and zero retention |
| May feed an admitted fact | yes, with a pinned digest | yes, with a pinned model id; never an alias |

**The zone check lives next to the client.** It is enforced in the profile resolver, where the call is made, not in a
policy check (which must not query) and not in the UI (which is not the only caller). A zone declaration is an
operator's authority for the deployment it covers; it is not a statement about what any customer agreement permits,
and no document should present it as one.

**Contract tests against both instruments.** CI carries a contract test — the same fixed set of questions and states
— against a local Ollaya and, where credentials exist, the hosted instrument, pinned to the SDK compatibility version
Ollaya declares, and run on synthetic data only. Its job is to detect wire drift between two parties with no agreement
between them. It is not an accuracy test; accuracy is calibration's job
([ADR 0041](0041-thresholds-are-dmn-earned-by-calibration.md)).

**Vendor risk, tiered per [thesis 6](../manifesto/06-reversibility.md).** `ash_ai` stays tier 2. The judgments package,
`ash_judgments`, is tier 3 — first-party, 0.x, confined to its own directory and one host domain. Both instruments are
services behind a network boundary (thesis 6's fourth category), and both clear its two rules: neither holds an
authorization model of its own, and removing either degrades triage rather than breaking the application. The hedge
against a twelve-day-old vendor is structural rather than contractual: the default path, generative rung included,
never depends on it.

**Deferred, each with its trigger.** Each item returns when its trigger fires, not before; the triggers are reviewed on
a schedule and recorded with the zone.

| Deferred item | Trigger that brings it back |
|---|---|
| Separate stacks per jurisdiction | Data from a second jurisdiction, any customer-visible output (leaving shadow mode), or moving the pipeline into a production environment outside the zone |
| Document masking | Any egress of customer-confidential text: a hosted model, outside labellers, hosted training, or any public artefact |
| A hosted instrument on customer documents | A question family misses its target locally *and* the hosted instrument beats local on a synthetic or public benchmark by a margin worth a contract, with a DPA and zero retention signed |
| A hosted reflection or teacher model for optimisers ([ADR 0047](0047-learning-produces-proposals.md)) | The in-zone reflection model shows no ranking signal on the development set; until then only synthetic question text and labels may leave |
| Encryption of the ledger's `state` ([ADR 0040](0040-record-dont-recompute.md)) | The first store outside the zone, or the first multi-user access to the zone |
| More inference capacity in the zone | Batch runtime for an evaluation set exceeds its window, or a needed model does not fit the zone's hardware |
| A formal security and legal approval record | Before any output is customer-visible, or before any customer-confidential data leaves a zone |

**Pending, and marked so:**

- where the runtime is placed and sized in each zone — an operational record kept with the zone, not doctrine — and
  the cold-start budget;
- the default local model (`laya`, `winnow` or another), after the licence audit and a measured spike;
- whether an *emulated* profile — typed decisions extracted from chat models' log-probabilities — is admitted at all.
  If it is, it is a separate calibration family, never pooled with native System One answers.

## Does it consume ActorContext?

**Not directly, and it cannot — the same shape as ADR 0026.** Inbound, the evaluate action runs as the requesting actor,
so the state reaching any instrument is what that actor could already read. Outbound, neither Ollaya nor a hosted
vendor can evaluate a grant, and neither is asked to: they hold no permission model to synchronize, which is precisely
why they pass thesis 6's first rule. The zone rule and the per-tenant opt-in are configuration read by the client,
deliberately outside the policy layer.

## Consequences

**What this makes easy.** The questionnaire sentence "no customer data leaves its declared zone for inference by
default, and the egress log proves it" is true by construction and checkable from the ledger. An empty egress log for
customer-confidential data is the demonstrable privacy claim. Real documents can be processed from the first week,
inside the zone, without first building masking or signing a hosted contract. Vendor failure, repricing or a changed
retention policy costs benchmark access, not operation.

**What it makes hard.** Someone has to run, size, patch, pin and monitor an inference runtime in every zone, including
checking that it ran on the hardware intended. Local models are much smaller than the hosted one — 1,024 tokens against
64k for the default router model — so questions have to be decomposed further, and some whole-document questions the
hosted model could answer in one call are unavailable locally. The larger decision model does not fit a single consumer
GPU. Local accuracy is unmeasured on our questions until the spike runs. The deferred items are real work waiting on
triggers, and someone has to watch the triggers.

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

**What it forecloses.** A hosted-only design. Silent routing of a tenant's data to a gateway. A single global
evaluation set or metric. Treating masking inside the zone as a privacy control, or an operator's declaration as
customer consent.

## Reversal

Zones and profiles are configuration resolved by one function. Splitting into per-jurisdiction stacks is declaring more
zones and moving stores, which the jurisdiction dimension already anticipates. Making hosted the default is a one-line
change in that resolver plus the disclosure and contract work ADR 0026 already describes — cheap in code, expensive in
paperwork, and it should be. Dropping the local runtime is removing a process from the zone and a profile from
configuration; the ledger keeps every answer it already recorded.
