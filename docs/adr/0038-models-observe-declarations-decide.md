# ADR 0038 — Models observe; declarations decide

- **Status:** proposed
- **Date:** 2026-09-27
- **Amended:** 2026-09-28 — the generative rung is in-zone and schema-constrained (ADR 0046); learning loops end in
  proposals (ADR 0047); a fact about local runtimes added
- **Amended 2026-09-28 (operator answers):** the hosted model is never an instrument — the only instruments are
  decision models served in the zone and in-zone generative runtimes; the inference pipeline is a separate subsystem
  that consumes declarations; no novelty framing

## Context

A class of model makes a probabilistic judgment cheap enough to put almost anywhere. "System One" models — the
name is the vendor's, borrowed from the fast, intuitive half of Kahneman's pair — answer a typed question (yes/no, pick
one of N, score on a scale) over a piece of text and return a probability distribution rather than generated prose.
They run in milliseconds and cost little enough per call that "ask the model" stops being an architectural event and
becomes a line of code. That is the risk this record exists to contain.

The facts, verified on 2026-09-27:

- **The call already exists in a dependency this repository locks.** `ash_ai` 1.1.0 (hex, released 2026-09-18) ships
  `AshAi.Actions.Evaluate`, used as `run evaluate(model, ...)` inside a generic action, with answer types
  `AshAi.Evaluate.Noul` (a probability), `Choice` (a value, a distribution and a confidence), `Score` (ordered levels)
  and `Judgments` (several questions in one request), behind an `AshAi.Evaluate.Answer` behaviour.
  `AshAi.Actions.Result` wraps the answer with the *versioned* model id behind any alias, and usage. `req_llm` 1.24.0
  ships the transport as a `typesafe` provider.
- **The wire protocol's vendor is new, and its hosted model is not available to this programme.** TypeSafe AI, which
  defined the protocol, emerged from stealth on 2026-09-15 — twelve days before this record. No public data-processing
  agreement or SLA was found for its hosted model, zero data retention is an enterprise contract rather than the
  default, and no self-hosted option is documented. That vendor risk is why the design is local-first; the programme
  has no access to the hosted model in any case, so it is **never an instrument** here. What is kept is the wire
  specification.
- **A local instrument exists and is independent.** Ollaya is an Apache-2.0 runtime (binary `ollaya`, port 11435) that
  speaks the same wire protocol and explicitly disclaims affiliation with the vendor. Compatibility is at the API level,
  not output parity. It serves decision models only, on ONNX Runtime and llama.cpp; it has **no generative endpoint**.
- **Generative local runtimes constrain their output.** llama.cpp's server, Ollama and vLLM each decode under a grammar
  compiled from a JSON Schema, and `req_llm` already reaches them (verified 2026-09-28; see
  [ADR 0046](0046-the-declaration-is-the-output-contract.md)).
- **The platform's existing rules forbid most of the places a model call would be convenient.** Policy checks never
  query ([thesis 3](../manifesto/03-authorization-is-data.md)); authorization is a pure union of grants with no
  `forbid_if` for row access; DMN evaluation is content-hashed, TCK-measured and time-bounded
  ([ADR 0028](0028-decisions-are-dmn.md)); compliance is a projection that must replay to the same answer
  ([ADR 0035](0035-compliance-is-projected-from-events.md)). A model is by construction not a reproducible function of
  its inputs across runtime versions, hardware or batching, and never will be.
- **`AshEvents` wraps only create, update and destroy.** A generic `evaluate` action is never audited on its own.
- **`ash_ai`'s `on_tool_start` callback is observe-only.** Its return value is discarded, so it cannot veto a tool call.

Nothing in this repository calls `evaluate` today. The decision is cheapest to make before the first call site exists.

## Decision

**A probabilistic model is a fact producer, never an authorizer and never an evaluator. Instruments observe; Ash
actions admit; declarations decide.**

The inference pipeline this record governs is a **separate subsystem that consumes declarations**. It reads the
questions, types, constraints, facts and tables the application already declares, and it adds nothing to what the
application derives from them; [thesis 1](../manifesto/01-model-your-domain.md)'s premise — declare once, derive the
rest — is unchanged by it.

Every probabilistic judgment in the platform follows one path, in three steps:

1. **Observe.** An instrument answers a *declared, typed question* ([ADR 0039](0039-judgments-are-declared-questions.md))
   and the answer is recorded as an observation with its full provenance ([ADR 0040](0040-record-dont-recompute.md)).
   The observation is data about what an instrument said, at a version, at a time. It asserts nothing about the world.
2. **Admit.** A deterministic Ash action turns an observation into a fact, or into a human task, or into nothing. The
   band that decides which is a versioned DMN table ([ADR 0041](0041-thresholds-are-dmn-earned-by-calibration.md)); the
   actor that performs the admission is either a human or a principal holding an explicit grant
   ([ADR 0043](0043-automation-authority-is-a-grant.md)).
3. **Decide.** Rules, policies and processes evaluate admitted facts exactly as they evaluate any other fact. They do
   not know a model was involved.

### Where a model call may and may not live

| Location | Legal? | Why |
|---|---|---|
| Policy check (`SimpleCheck`, `FilterCheck`, policy `expr`) | **Never** | Runs per request and per row. A model there is I/O, is nondeterministic, and — if it could deny — is a `forbid_if` on row access. |
| `ActorContext` build | **Never** | Computed once per request from a handful of queries by design. It may *read* a previously materialised fact; it may not infer one. |
| FEEL expression or DMN evaluation | **Never** | Breaks the content hash, the TCK measurement, `matched_rule_ids` and the 250 ms / 1 s bounds. Answers enter DMN as *inputs*. |
| `ash_rules` evaluation, or a fact builder on a guard path | **No live call** | The evaluator is pure. A fact builder may *read* the ledger. |
| Projector handler | **Never** | Projectors rebuild from event 0. They consume recorded observations. |
| Calculation | **Avoid** | Calculations are loaded in lists and filters and can be pulled into policy expressions. A calculation over the ledger is fine; a calculation over the model is not. |
| Generic action (`run evaluate(...)`) | **Yes — the primary home** | An explicit, named call, governed by policies, that records to the ledger. |
| Create or update change | **Yes, with care** | The call sits in `before_transaction`, and the answer is passed into the ledger create as an *input* (see ADR 0040 on replay). |
| AshOban trigger or scheduled action | **Yes — preferred for materialisation** | Idempotent, retried, carries ids rather than structs. |
| BPMN service task (`ash:call` to an evaluate action) | **Yes** | Durable, audited, with a human lane for the middle band. |
| Developer and agent tooling | **Yes, advisory** | See [ADR 0045](0045-system-one-in-tooling-is-advisory.md). |
| Offline optimiser or distillation job (searching question wording, mining rows) | **Yes — research and dev only; output is a proposal** | It never serves and never applies what it finds; see [ADR 0047](0047-learning-produces-proposals.md). |

### Never in a check, never a grant

A model answer may inform a fact. It may never be a grant, and it never runs inside a check. The only route by which a
judgment can touch authorization is as a **materialised, versioned, appealable fact** on an actor or session, loaded
into `ActorContext` like any other attribute, and used only for the concerns where `forbid_if` is already sanctioned —
a step-up requirement, a quarantined session. Whether any such use is wanted at all is **pending**; the recommendation
is none. Pruning an agent's tool list with `Ash.can?` is a user-experience measure and never a security boundary; the
action-layer policy stays the single gate ([thesis 5](../manifesto/05-agents-are-users.md)).

No model is ever handed a tool that admits, overrides or authorizes. Instruments get read-only tools or none.

### Three layers of outcome, never mixed

| Layer | Produced by | Values |
|---|---|---|
| **Evidence disposition** | the instrument | `supports`, `contradicts`, `insufficient`, `not_applicable` (optionally `wrong_scope`), each with a probability |
| **Admission** | the band table plus an authorized actor | `admitted` (a fact is written), `review` (a human task is opened), `omitted` (no fact is written) |
| **Rule outcome** | `ash_rules`, unchanged | `compliant`, `noncompliant`, `not_applicable`, `unknown`, `error` |

`review` is a workflow state, not a rule outcome, and neither is `omitted`: it is the admission action taken when a fact
is withheld. An omitted observation produces no fact, so a predicate declared `missing: :unknown` makes *the rule* —
not the admission — evaluate to `unknown`, and the lattice's existing guarantee holds: **uncertainty can never collapse
to compliant.** No code path converts a probability directly into a rule outcome.

### The ladder

Every question is answered on the cheapest rung that can answer it exactly:

1. **Declaration** — FEEL, rules, constraints, deterministic dimension checks (amounts, dates, units, parties). Free,
   exact, explainable. Used whenever the question is not intrinsically about interpreting language.
2. **System One** — typed, calibrated, milliseconds, always in the data's zone. Perception only: relevance, support
   or contradiction, classification, verifying a proposed value, routing.
3. **Generative model** — the residue: extracting open values, drafting text. Always in-zone, decoded under a
   schema derived from the Ash declaration ([ADR 0046](0046-the-declaration-is-the-output-contract.md)); leaving the
   zone is a disclosure ([ADR 0042](0042-in-zone-inference-leaving-the-zone-is-a-disclosure.md)). Its output carries no
   self-reported confidence, cites only by constrained id, and is only ever a proposal that a declaration or System One
   then checks. A schema-valid answer is well-formed, not correct.
4. **Human** — the middle band and anything high-consequence. Their verdicts are events and become the evaluation set.

Descending the ladder is triggered by calibrated uncertainty declared in a band table, never by code. Where a
declaration can decide, a model must not.

## Does it consume ActorContext?

**Yes, and this record is mostly about keeping it that way.** Every evaluate action is an ordinary generic action, run
as the requesting actor, through the same policies; the state an instrument sees is what that actor could already read
([ADR 0026](0026-ai-governance-is-disclosure.md)'s inbound half, unchanged). The rule this record adds is the other
direction: nothing a model returns is ever *computed into* `ActorContext`. A judgment that matters to authorization is
materialised first, by an action, as a row — and `ActorContext` reads the row, never the model. A policy check that
called an instrument would be a bug of exactly the kind non-negotiable 3 names.

## Consequences

**What this makes easy.** The model becomes a replaceable part. Because nothing authoritative depends on a live answer,
swapping a model or a runtime is a change to what gets *observed*, reviewed like a rule change, rather than a
change to what the application *does*. Every existing guarantee — the union of grants, the replayable projection, the
TCK number, the rules lattice — survives untouched, because none of them ever sees a probability.

**What it makes hard.** Everything is a step slower than calling the model inline. Observation, admission and decision
are three places to look instead of one, and the convenient shape — "if the model says so, allow it" — is refused
everywhere it would be convenient. A background materialisation step is needed wherever a judgment has to be available
on a request path, which means judgments can be stale, and staleness has to be declared per question family. Every
learning loop — optimising question wording, distilling overrides, fine-tuning — ends in a proposal that travels the
approval lifecycle ([ADR 0047](0047-learning-produces-proposals.md)), so improving the model's inputs is as slow as
changing a rule, on purpose.

**What it forecloses.** Adaptive authorization driven by a live score. Model calls inside FEEL (the unwired
`external_functions` seam in the DMN engine stays unwired for this purpose). Treating a high probability as a verdict.
Deliberately, all of them.

**The honest limit.** This record fences the model so tightly that its direct value narrows to triage throughput and
verification. That is the intended claim, and the programme should be judged on it — see the steelman in
[thesis 8](../manifesto/08-models-observe-declarations-decide.md).

## Reversal

Nothing is built, so today the reversal is deleting this record and its nine siblings (0039–0047). Once built, the fence
is what makes the reversal cheap: instruments are reached only through evaluate actions in the judgments package and its
host modules, and every downstream consumer reads admitted facts rather than model output. Removing System One deletes
the package, its host directory and its ledger migration; admitted facts already written stay valid as facts, and
predicates that depended on future admissions fall back to `unknown` and to the human lane — a degraded feature, not a
broken application.
