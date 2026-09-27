# ADR 0046 — The declaration is the output contract

- **Status:** proposed
- **Date:** 2026-09-28

## Context

[ADR 0039](0039-judgments-are-declared-questions.md) made the Ash declaration the source of every System One
question: options come from constraints, so a model cannot choose an option the schema does not have. The generative
rung ([ADR 0038](0038-models-observe-declarations-decide.md)'s ladder) was left without the same discipline. Its
output — an extracted limit, a proposed citation, a composed surface — has a shape, and something has to say what that
shape is, where it is enforced, and what enforcing it does and does not prove.

A proposal in circulation answers "derive the output schema from Dialyzer types and verify tool contracts at compile
time". This record exists to answer that premise in one place, because it collides with
[ADR 0007](0007-dialyzer-non-blocking.md), and because most of what it asks for already exists.

The facts, verified on 2026-09-28 by probing the locked dependencies (`ash_ai` 1.1.0, `req_llm` 1.24.0, Elixir 1.20):

- **`ash_ai` already derives the output schema from the declaration.** A prompt action's return type and constraints
  are turned into a JSON Schema, sent through `ReqLLM.generate_object/4` as each provider's native structured-output
  mechanism, and the reply is re-cast with `Ash.Type.cast_input` and `apply_constraints`. A failed cast is an error,
  not a retry. The same type-to-schema mapping builds tool *input* schemas.
- **Part of the contract reaches the wire; part is enforced only afterwards.** Enums, required fields, closed objects,
  numeric bounds and formats are on the wire, so a grammar-capable runtime enforces them during decoding. String
  length and pattern, array length, decimal bounds and per-item constraints are dropped from the wire schema and
  enforced only by the Ash re-cast. An extra key in a closed object is accepted and silently dropped.
- **Atom-keyed schemas bypass provider sanitisers.** `ash_ai` emits its inner schema with atom keys; `req_llm`'s
  per-provider sanitisers (which strip keywords a provider does not support) match string keys only, so they do not
  run. Whether the affected provider rejects or ignores the leftover keywords was not verified live.
- **There is no per-call narrowing.** The schema is built from static action constraints, so "`source_ids` must be one
  of this packet's atom ids" or "`surface` must be in the live catalogue" cannot be put on the wire. Today such
  constraints live in prompt prose.
- **MCP tools publish no `outputSchema`**, though MCP 2025-06-18 defines one (servers must conform, clients should
  validate) and `ash_ai`'s server already sends `structuredContent` and negotiates that version.
- **Ash does not cast hand-written generic-action returns.** A generic action declared to return an atom with
  `one_of: [:supports, :contradicts]` whose `run` returns `{:ok, :maybe}` returns `{:ok, :maybe}`; a map with a bounded
  field returned out of bounds passes unchanged. Only `prompt` and `evaluate` implementations cast.
- **Grammar-constrained decoding is available locally.** llama.cpp's server (`json_schema`, or a raw GBNF grammar),
  Ollama and vLLM compile a JSON Schema into decoding constraints, each with its own keyword coverage (llama.cpp, for
  example, supports string and array length and anchored patterns but bounds only on integers). `req_llm` reaches them.
  **Ollaya does not**: it is a decision-model runtime with no generative endpoint; its models are output-constrained by
  construction, as typed answers.
- **Neither Dialyzer nor Elixir 1.20 inference can be the source.** Dialyzer success typings lose every refinement
  (length, pattern, bounds, decimals) and are unreliable over Spark-generated code, which is why ADR 0007 makes them
  advisory. Elixir 1.20's inferred types are real and useful, but carry no refinements and are reachable only through
  an internal compiler chunk (`:elixir_checker_v8`) with no public API. A prompt action has no Elixir implementation to
  type in any case: the model is the producer.
- **The idea is not new.** TypeChat (2023) validates model output against declared TypeScript types and feeds compiler
  diagnostics back as a repair prompt; type-constrained decoding (Mündler et al., PLDI 2025) constrains generation with
  a type system; BAML and schema-derived structured output are standard practice. What this record adds is where the
  source lives and what a valid answer is allowed to mean.

## Decision

**The Ash declaration is the only source of every model output shape. The shape is enforced at decode time where the
runtime can, and by the Ash cast always. A schema-valid answer is a well-formed proposal, never a true one.**

1. **Ash types and constraints are the only source** of every model output shape: System One options
   ([ADR 0039](0039-judgments-are-declared-questions.md)), generative JSON Schema, tool input, and MCP `outputSchema`.
   Typespecs, Dialyzer PLTs and inferred types are never a source. A generated `@spec` is a derived artefact.
2. **One mapping.** Type → JSON Schema is generated once, from `Ash.Info.Manifest.Type`, string-keyed, and shared by
   every consumer — prompt output, tool input, MCP, and the agent tooling's `describe`.
3. **Decode-time where possible, cast always.** Whatever the runtime can enforce goes on the wire. The Ash cast is the
   validator of record for everything, refinements included. A failed cast is recorded as an observation of failure,
   never silently repaired.
4. **Per-call narrowing.** Where the admissible values depend on the call — a packet's atom ids, a live catalogue — the
   schema is narrowed per call from declared inputs. The constraint lives in decoding, not in prose.
5. **No self-reported confidence** on the generative rung. A model-emitted `confidence` number is not a calibrated
   probability, so the schema has no such field. Every enum carries an abstention value (`not_found`, `ambiguous`,
   `insufficient`), and every extracted field is nullable: forcing an enum with no way to abstain manufactures confident
   wrong answers.
6. **The wire schema is part of the instrument's identity**, and its hash is recorded on every generative observation
   ([ADR 0040](0040-record-dont-recompute.md)). Changing a constraint that reaches the wire is an instrument change.
7. **Schema-valid is not correct.** Constrained decoding fixes shape, not truth. A decoded answer is a proposal
   ([ADR 0038](0038-models-observe-declarations-decide.md)), verified by System One against the atom ids it cites
   ([ADR 0044](0044-documents-are-addressed-atoms-evidence-is-an-assertion.md)) and by deterministic checks. No
   surface may describe a constrained output as guaranteed true.
8. **Implementation ⊆ declared** for hand-written generic actions is checked in two ways:
   - by a runtime cast of generic-action returns on the platform base, in development and test;
   - by an advisory static check in the agent tooling (`mix ash_agent.contracts`) over the compiler's inferred types,
     reporting *proven*, *refuted* (with a witness value) or *unknown*.

   Neither gates until promoted by a versioned threshold ([ADR 0045](0045-system-one-in-tooling-is-advisory.md)).

**Upstream first.** The gaps above belong upstream, and are proposed there rather than patched here: a string-keyed,
refinement-complete output schema from one mapping in `ash_ai`; per-call output constraints for prompt actions; MCP
`outputSchema` for typed returns; and string-key normalisation before sanitising in `req_llm`. The agent tooling's
`describe` gains return constraints.

## Does it consume ActorContext?

**No, because a schema is derived from declarations, not from grants.** Per-call narrowing uses only data the requesting
actor has already loaded — the packet's atoms, for example, which were read under that actor's grants
([ADR 0044](0044-documents-are-addressed-atoms-evidence-is-an-assertion.md)) — so narrowing can shrink what a model may
cite but never widen what the actor may see. The return guard and the static check run in development, test and CI over
code, with no actor at all.

## Consequences

**What this makes easy.** One change to a constraint moves every contract at once: the attribute, the question, the
prompt output, the tool input and the MCP description. A fabricated citation becomes undecodable rather than merely
detectable. A hand-written action that returns a value its declaration forbids is caught in test instead of in
production.

**What it makes hard.** Runtimes differ in keyword coverage — one hosted provider strips numeric and length bounds, and
llama.cpp bounds only integers — so schemas have to be tested per provider request body, and the Ash cast can never be
skipped. The static check depends on an internal compiler chunk and must refuse, with a structured "unsupported
compiler" result, rather than guess when the chunk changes. Per-call narrowing needs an upstream hook that does not
exist yet.

**What it forecloses.** Output schemas derived from Dialyzer or `@spec`. Confidence fields on generative output.
Constraints written in prompt prose where decoding could hold them. Describing constrained decoding as a guarantee of
correctness.

## Reversal

The re-cast is upstream behaviour and stays whatever happens to this record. Reversing it means removing the per-call
narrowing hook, the platform's return guard and the advisory contracts task; output shapes then revert to whatever the
upstream mapping produces, with constraints enforced after the fact rather than during decoding. ADR 0007 is untouched
either way.
