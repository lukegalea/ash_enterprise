# ADR 0039 — Judgments are declared questions

- **Status:** proposed
- **Date:** 2026-09-27

## Context

[ADR 0038](0038-models-observe-declarations-decide.md) makes every probabilistic judgment the answer to a question.
This record decides what a question *is*, and what code this platform writes to ask one.

The facts, verified on 2026-09-27:

- **The call is upstream.** `ash_ai` 1.1.0 (hex, 2026-09-18) implements `AshAi.Actions.Evaluate` as a generic-action
  implementation. The action's *arguments* are the state; the questions come from its *return type*; the typed result
  is cast back into that return type. A `questions:` option supports runtime question sets and a `state:` option lets a
  host send a projection of the arguments instead of the arguments themselves.
- **The answer types are upstream.** `AshAi.Evaluate.Noul`, `Choice` (whose `of:` takes an `Ash.Type.Enum` or runtime
  criteria), `Score` and `Judgments`, behind the `AshAi.Evaluate.Answer` behaviour (`answer_fields/1`, `to_question/3`,
  `from_answer/2`). New answer kinds are an implementation of that behaviour, not a fork.
- **The transport is upstream.** `req_llm` 1.24.0 ships `ReqLLM.evaluate/4` and a `typesafe` provider that posts to
  `/v1/systemone` and honours a per-call `base_url`. A tuple model spec such as
  `{:typesafe, "laya", base_url: "http://localhost:11435", api_key: "local"}` reaches a local Ollaya runtime with no
  new code. Two caveats: `req_llm` does **not** read a `TYPESAFE_BASE_URL` environment variable (the base URL is a
  compile-time default unless passed per call), and its option schema is closed, so custom metadata cannot ride through
  it.
- **There is no official Elixir SDK from the vendor**, and at least four unofficial community clients, none confirmed
  maintained. That fact mattered before `req_llm` shipped a provider; it no longer does.
- **This repository already resolves a model per call.** `AshEnterprise.AI.RequestClassifier` passes
  `&AshEnterprise.AI.model/0` as a capture rather than a value, because a `prompt/2` argument evaluated at compile time
  baked build-time configuration into the release.
- **Instrument limits are real and small.** Ollaya accepts at most 256 questions per request; a `Choice` takes 2–255
  options, with a practical ceiling of roughly 125–250 depending on the model. The local `laya:typed-decisions` model's
  context is **1,024 tokens** (512 for `laya:en`); `decider` is 32k; hosted Jev is 64k. Ollaya now recommends
  `winnow:e4b` as its default model.

## Decision

**A question is a declaration: typed by an Ash type, options drawn from constraints, versioned, content-hashed, and
answered by `ash_ai`'s `evaluate`. This platform writes no HTTP client, no provider behaviour and no answer types.**

**The registry.** Questions are declared in a Spark DSL section on the resource or domain that owns the subject:

```elixir
judgments do
  question :liability_limit_evidence do
    answer AshAi.Evaluate.Choice
    of MyApp.EvidenceStance            # supports | contradicts | insufficient | not_applicable
    instructions "Does `passage` state a general-liability limit of at least `required_limit`?"
    version 3
    family :insurance_limits           # the calibration grouping (ADR 0041)
    state {MyApp.Coverage, :for_question}  # a projection: only what the question needs
  end
end
```

The section name and exact grammar are the package's to settle; the properties are not:

1. **Options come from constraints.** A `Choice` over a field is typed by the field's own `one_of` or enum. The same
   declaration that validates an attribute is the list a model may choose from, so a model cannot invent an option,
   and adding an option is a schema change that shows in the manifest like any other.
2. **Identity is a content hash.** The hash covers the instructions, the criteria, the answer type, the options and the
   version. It is the question's identity in the ledger, exactly as the DMN definition hash and the rule bundle hash are
   theirs. Editing the wording is a new question.
3. **State is a projection.** A question declares what it sends. Sending a whole record because it was convenient is a
   disclosure decision made by accident ([ADR 0026](0026-ai-governance-is-disclosure.md)).
4. **It compiles to evaluate actions.** A single-question action and a matrix action (`{:array, answer}` with runtime
   `questions:`) for evidence work across many passages. They are ordinary generic actions, so they are policy-governed,
   callable from BPMN `ash:call`, and exposable as tools.
5. **Because it is DSL, it is visible.** The registry surfaces through the same introspection as every other
   declaration — the semantic manifest, the agent tooling's search, the documentation — without a second catalogue.

**The one new answer kind worth adding is `Evidence`**: a `Choice` over the four-way disposition with fixed criteria
text. It is generic, so it is proposed upstream to `ash_ai` rather than kept here.

**Profile resolution is host code.** The package resolves a named profile (`:local`, `:hosted`, and later an emulated
profile over chat models) to a `req_llm` model spec at call time, through a 0-arity capture, following the existing
`request_classifier.ex` pattern. Which profile is the default, and what each discloses, is
[ADR 0042](0042-local-first-inference-hosted-is-disclosure.md).

**Every answer says which rung produced it.** Any surface that shows a judgment shows its provenance alongside:
*answered by System One · model@digest · p = 0.94 · 7 ms*, or *answered by rule R-12*, or *answered by a reviewer*. A
generative model's text is labelled commentary. The chip is derived from the ledger row, so it cannot claim more than
was recorded.

**Package boundary.** The judgments package (working name `ash_ai_systemone`; a vendor-neutral name is **pending**)
owns the registry, profiles, the ledger fragments, cache, replay, shadow, calibration storage, the DMN bridge and
telemetry. It never calls a model inside a check, a FEEL expression, a rule evaluation or a projector, and never holds
a threshold in configuration.

## Does it consume ActorContext?

**Yes, by being nothing special.** An evaluate action is a generic action on a resource, reached through the same
policies as every other action, with the requesting actor. The state projection runs over what that actor loaded, so a
question cannot be used to read past the actor's grants. A question declared on a resource with no read grant for the
caller is unreachable for the same reason any other action is.

## Consequences

**What this makes easy.** One declaration answers four audiences: the model (the question), the ledger (the hash), the
manifest and agent tooling (the DSL entity), and the auditor (the version history). Adding a question is adding a
declaration; a code review sees the wording, the options and the state it sends in one place.

**What it makes hard.** Wording is now versioned policy. Tuning a question's phrasing mints a new identity, orphans its
calibration, and has to be re-earned ([ADR 0041](0041-thresholds-are-dmn-earned-by-calibration.md)) — which is
correct, and slower than editing a prompt. The 1,024-token context of the default local model forces small states;
questions that need a whole document have to be decomposed or sent to a larger instrument by declared profile.

**What it forecloses.** Ad-hoc model calls with inline prompt strings in application code. Answer types defined by this
platform in parallel with upstream's. A bespoke HTTP client for the vendor's API.

## Reversal

The registry is a DSL section and the answer types are upstream, so the reversal is deleting the section from the
resources that carry it and the package from `mix.exs`. Evaluate actions disappear with the section; any caller of
them — a BPMN service task, an Oban trigger — fails at compile time or at process publish, loudly. If `ash_ai` removed
`evaluate` upstream, the package would carry the call itself behind the same `Answer` behaviour, one module wide.
