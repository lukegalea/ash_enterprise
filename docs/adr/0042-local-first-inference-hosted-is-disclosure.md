# ADR 0042 — Local-first inference; hosted inference is a disclosure

- **Status:** proposed
- **Date:** 2026-09-27

## Context

The question-and-answer surface ([ADR 0039](0039-judgments-are-declared-questions.md)) is the same whichever
instrument answers it. Where the instrument runs is a separate decision, and it is the one a security questionnaire asks
about.

The facts, verified on 2026-09-27:

- **Hosted.** TypeSafe AI emerged from stealth on 2026-09-15 with a $40M seed round — **twelve days** before this
  record. Its model, Jev, is text-only; its request context is 64k tokens (32k for the state); `jev-1.13.0` is pinnable
  and the `-latest` and `-preview` aliases move. Input is priced at $0.042 per million tokens. It is also reachable
  through OpenRouter and Cloudflare Workers AI, each of which adds its own data policy. Zero data retention is an
  enterprise contract, not the default. No public data-processing agreement, SLA or self-hosted option was found. Its
  performance claims are self-reported.
- **Local.** Ollaya is an independent, Apache-2.0 runtime for decision models that **explicitly disclaims affiliation**
  with the vendor. Its binary is `ollaya` (not `ol`, as some earlier notes have it); it serves on port 11435; it is
  wire-compatible with the vendor's Python SDK 0.7.1 at the API level, **not** at the level of output parity. It runs
  CPU-only everywhere and on NVIDIA GPUs under Linux. A first request can take longer than ten seconds while a model
  loads, which trips default client timeouts. It exposes an MCP server (`ollaya mcp`).
- **Local models are small and carry their own licences.** `laya:typed-decisions` (421M parameters, Apache-2.0) has a
  **1,024-token** context; `decider` (built on Qwen3.5, 0.8b–4b) has 32k and works by reading next-token logits for
  option letters; Ollaya now recommends `winnow:e4b` as the default. Bundled models retain their own licences — a mix of
  Apache-2.0, MIT and proprietary — which have not yet been audited for this use.
- **The transport is indifferent.** `req_llm`'s `typesafe` provider takes a per-call `base_url`, so the same evaluate
  action reaches either instrument by profile.
- **[ADR 0026](0026-ai-governance-is-disclosure.md)** (proposed) treats a model call as an outbound disclosure to a
  sub-processor: log prompt and response under the tenant and correlation id, record vendor and version, and enforce a
  per-tenant opt-out next to the client.
- **Region is already a boundary.** A deployment that runs separate regional stacks must keep every observation, cache
  entry, evaluation set and metric within the region it came from; a total that silently covers one region is the
  commonest way such numbers go wrong.

## Decision

**The default instrument runs in-cluster, per regional stack. A hosted instrument is an opt-in profile, and choosing it
is a sub-processor disclosure under ADR 0026.**

**Profiles carry residency.** Each profile declares `residency: :in_cluster` or `residency: :sub_processor` alongside
its model spec. The residency, not the vendor name, is what governance reads:

| | `:in_cluster` (Ollaya in the region's stack) | `:sub_processor` (hosted Jev, or via a gateway) |
|---|---|---|
| Default | **yes** | no — explicit per-tenant opt-in |
| ADR 0026 treatment | recorded in the ledger; not an outbound disclosure | outbound disclosure: vendor, model version, gateway, tenant, correlation id |
| Tenant enablement | n/a — always on, data does not leave the boundary | off unless a tenant explicitly opts in; the opt-in is recorded as tenant data and checked next to the client, before the call |
| Contract prerequisite | model licence audit | signed DPA and a zero-retention contract before any customer document is sent |
| May feed an admitted fact | yes, with a pinned digest | yes, with a pinned model id; never an alias |

**The residency check lives next to the client.** It is enforced in the profile resolver, where the call is made, not
in a policy check (which must not query) and not in the UI (which is not the only caller).

**Region is a dimension of everything.** Every ledger row, cache key, calibration run and metric carries its region. A
calibration run in one region does not license a band table in another. There is no cross-region total without the
region shown.

**Contract tests against both instruments.** CI carries a contract test — the same fixed set of questions and states
— against a local Ollaya and, where credentials exist, the hosted instrument, pinned to the SDK compatibility version
Ollaya declares. Its job is to detect wire drift between two parties with no agreement between them. It is not an
accuracy test; accuracy is calibration's job ([ADR 0041](0041-thresholds-are-dmn-earned-by-calibration.md)).

**Vendor risk, tiered per [thesis 6](../manifesto/06-reversibility.md).** `ash_ai` stays tier 2. The judgments package
is tier 3 — first-party, 0.x, confined to its own directory and one host domain. Both instruments are services behind a
network boundary (thesis 6's fourth category), and both clear its two rules: neither holds an authorization model of its
own, and removing either degrades triage rather than breaking the application. The hedge against a twelve-day-old
vendor is structural rather than contractual: the default path never depends on it.

**Pending, and marked so:**

- whether a hosted instrument is ever acceptable for customer documents. The recommendation: benchmarking on synthetic
  or public data only, and no customer documents until a DPA and a zero-retention contract are signed;
- where the local runtime is placed and how it is sized per region (CPU or GPU, which hosts), and the cold-start budget;
- the default local model (`laya`, `decider` or `winnow`), after the licence audit and a measured spike;
- whether an *emulated* profile — typed decisions extracted from chat models' log-probabilities — is admitted at all.
  If it is, it is a separate calibration family, never pooled with native System One answers.

## Does it consume ActorContext?

**Not directly, and it cannot — the same shape as ADR 0026.** Inbound, the evaluate action runs as the requesting actor,
so the state reaching either instrument is what that actor could already read. Outbound, neither Ollaya nor a hosted
vendor can evaluate a grant, and neither is asked to: they hold no permission model to synchronize, which is precisely
why they pass thesis 6's first rule. The per-tenant opt-in is tenant configuration read by the client, deliberately
outside the policy layer.

## Consequences

**What this makes easy.** The questionnaire answer "no customer data leaves your region for inference by default" is
true by construction and checkable from the ledger. Vendor failure, repricing or a changed retention policy costs
benchmark access, not operation.

**What it makes hard.** Someone has to run, size, patch and monitor an inference runtime in every regional stack. Local
models are much smaller than the hosted one — 1,024 tokens against 64k — so questions have to be decomposed further,
and some whole-document questions that the hosted model could answer in one call are simply unavailable locally.
Local accuracy is unmeasured on our questions until the spike runs.

**What it forecloses.** A hosted-only design. Silent routing of a tenant's data to a gateway. A single global
evaluation set or metric.

## Reversal

Profiles are configuration resolved by one function. Making hosted the default is a one-line change in that resolver
plus the disclosure and contract work ADR 0026 already describes — cheap in code, expensive in paperwork, and it should
be. Dropping the local runtime is removing a process from the deployment and a profile from configuration; the ledger
keeps every answer it already recorded.
