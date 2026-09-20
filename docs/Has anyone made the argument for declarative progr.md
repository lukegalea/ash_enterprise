<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" style="height:64px;margin-right:32px"/>

# Has anyone made the argument for declarative programming being better for working with llms as a means of reducing how much non-determinsism is in the spec to app process?

Yes. This argument shows up repeatedly, and the strongest versions are specifically about shrinking the **spec → artifact** solution space so the model fills a schema instead of inventing an architecture. The claim is not that LLMs become deterministic; it is that declarative targets move most of the “how” into a compiler or runtime, so equivalent specs produce far fewer inequivalent apps.[^1_1][^1_2]

## The Core Claim

Give an LLM the same product spec twice in an imperative stack and you usually get two working, incompatible implementations: different error handling, state models, retries, naming, and layering. That is non-determinism in the *process*, not just in tokens. A declarative target collapses that: the LLM emits facts, transitions, constraints, or config; a deterministic compiler owns the rest.[^1_2][^1_1]

The Loj experiment is the closest statement to your framing. The author argues humans find declarative hard because they want to inspect every `if`, while LLMs fail at keeping the same business rule consistent across React, API, permissions, and persistence. Declaring `transition: approve` and compiling it into UI, backend, and auth removes that cross-stack tracking problem. Schema-checked DSLs also turn common agent failure modes into linter errors instead of silent architectural drift.[^1_1]

Hiop makes the same point for AI-generated data pipelines: LLMs generate working code, not consistent code. Their 18-month data on 50 projects claimed imperative pipelines spent 60% of time on maintenance versus 15% for declarative ones. The punchline is operational, not aesthetic: “the AI isn’t writing code, it’s filling out a form.”[^1_2]

## Who Has Made It

The argument appears in several independent clusters:

- **Constrained DSLs as the generation target.** Loj compiles one declaration into React plus Spring/FastAPI. PayPal’s agent DSL treats workflows as data, not code, so the same pipeline runs on Java, Python, or Go. IBM reports a declarative NL-to-query approach beating agentic/imperative code generation on heterogeneous data sources.[^1_3][^1_4][^1_1]
- **Deterministic generators plus LLMs.** Carracedo splits apps into structural code (homogeneous, majority of the codebase) and business-logic code. Use declarative/model-based generators for the first; reserve probabilistic generation for the second. Narrowing the LLM’s scope is the reliability move.[^1_5]
- **Structured “what,” not choreography.** Bounti argues that once the system is a schema plus template, the LLM only has to emit valid data. JSON-schema validation is milliseconds; compiling and inspecting procedural code is minutes and much noisier.[^1_6]
- **Declarative formalization for solvers.** Work on symbolic solvers found “declarative exemplar prompting” improved correctness by stopping models from emitting skipped-step imperative Prolog. The model translates the spec into constraints; the solver does the search.[^1_7]
- **Intent-based / SPL-style systems.** These treat the developer artifact as a declared desired state, then let an agent or mixed probabilistic/deterministic runtime realize it. SPL’s pitch is SQL-like: declare *what* and *in which mode*, rather than how to coordinate the two.[^1_8][^1_9]

Haskell/static-FP people make a weaker cousin of the same claim: high-level declarative code plus types is easier for models to generate and for humans to review, because invalid programs are rejected earlier.[^1_10]

## Why Variance Actually Drops

The mechanism is cardinality plus feedback, not magic.

An imperative app has a huge set of observationally similar programs. An Ash resource, SQL query, Terraform file, BPMN/DMN model, or JSON schema has a much smaller set of valid encodings of the same intent. The compiler then maps that encoding to a *single* implementation of buttons, policies, retries, and persistence. That is how you remove non-determinism from spec-to-app without requiring the LLM itself to be deterministic.[^1_1][^1_2]

Verification also changes shape. You check types, required keys, enums, invariants, and schema conformance instead of reading a novel of `useEffect` and try/catch. Compact source also matters: Loj’s flight-booking example is ~1,100–1,300 lines versus ~13,000 lines of React plus Spring, which is an explicit context-window argument.[^1_6][^1_1]

A familiar illustration in your stack is an order-approval rule. Imperative generation has to keep this consistent in LiveView, context, API, changeset, and tests:

```elixir
# LLM can invent a different version of this in every layer
if order.status == :pending and actor.role == :admin do
  approve(order)
end
```

Declarative generation emits one fact; the framework owns the rest:

```elixir
# One declaration; policies, UI affordances, and API can compile from it
policies do
  policy action(:approve) do
    authorize_if actor_attribute_equals(:role, :admin)
  end
end
```

Same spec, fewer degrees of freedom, a deterministic remainder.

## Two Arguments That Get Mixed

“Declarative is better for LLMs” is used for two almost opposite things.

**Declarative target languages** reduce freedom in the artifact. That is your non-determinism claim.[^1_2][^1_1]

**Declarative prompts** increase freedom in the *path*. Constraint-based prompting says “User MUST have `email: string` with RFC 5322 validation” instead of “open `schema.ts`, then…”. That makes agents more robust, but it does not by itself make two runs produce the same app. It often does the reverse unless the target is also constrained.[^1_11]

The useful synthesis is: declare intent and invariants to the model, then force the model to emit a declarative, checkable artifact, then compile. Non-determinism is allowed in search, not in the shipped system.

## Where The Argument Breaks

Declarative targets do not eliminate irreducible business logic. Carracedo is right that app-specific behavior still needs improvisation, which is exactly where LLMs earn their keep. Escape hatches grow; Loj itself estimates 5–10% of a sample app as escape-hatch code, mostly CSS.[^1_5][^1_1]

Schema bloat is the classic failure mode: Kubernetes, Terraform, and dbt all show YAML quietly becoming an imperative language. Hiop’s answer is constrained scope plus explicit imperative exits, not an infinite schema. Designing those primitives so they stay semantically neutral across React, SwiftUI, Spring, and async workflows is the hard language-design problem, not the LLM problem.[^1_1][^1_2]

So the mature version of the argument is architectural: put a declarative, typed, lintable intermediate representation between spec and running system. Use the LLM to populate that IR. Use a compiler for everything that should not vary. That is how you buy determinism in the spec-to-app path without pretending the model is a compiler.

<span style="display:none">[^1_12][^1_13][^1_14][^1_15]</span>

<div align="center">⁂</div>

[^1_1]: https://www.reddit.com/r/programming/comments/1ruzqmc/why_declarative_programming_is_harder_for_humans/

[^1_2]: https://blog.hiop.io/imperative-pipelines-cost-4x-more-to-maintain-heres-why-declarative-wins-for-ai-generated-code/

[^1_3]: https://arxiv.org/html/2512.19769v1

[^1_4]: https://research.ibm.com/publications/declarative-techniques-for-nl-queries-over-heterogeneous-data

[^1_5]: https://dev.to/carracedo/probabilistic-vs-deterministic-choosing-the-right-code-generator-1nin

[^1_6]: https://bounti.ai/blog/engineering/declarative-video-ai

[^1_7]: https://www.themoonlight.io/en/review/when-do-symbolic-solvers-enhance-reasoning-in-large-language-models

[^1_8]: https://vucense.com/ai-intelligence/agentic-ai/prompt-engineering-is-dead-the-rise-of-intent-based-software-development/

[^1_9]: https://www.alphaxiv.org/abs/2607.07727

[^1_10]: https://news.ycombinator.com/item?id=46582728

[^1_11]: https://understandingdata.com/posts/constraint-based-prompting/

[^1_12]: https://arxiv.org/html/2601.02060v1

[^1_13]: https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/declarative-agent-manifest-1.4

[^1_14]: https://www.alphaxiv.org/abs/2512.19769v1

[^1_15]: https://www.scribd.com/document/968620387/Adl-A-Declarative-Language-for-Agent-based


---

# What about an argument that shows z3 vs imperative solution for schedule optimization or something as an extreme example?

Yes. Scheduling versus Z3 (or CP-SAT) is the extreme form of the same argument: the LLM should emit constraints, not a search procedure, because search is where both **wrongness** and run-to-run variance explode.[^2_1][^2_2]

## Why This Is Extreme

In the Ash/SQL case, an imperative LLM still often produces *some* working app. In scheduling, the “how” is combinatorial search over an exponential assignment space. An LLM asked to *produce the schedule* is being asked to be a solver. It is a bad one, and a different bad one each time.[^2_2]

SCHEDBench makes that empirical. Thirteen models were asked to emit schedules for 1,132 job-shop, RCPSP, nurse-rostering, and timetabling instances. Cross-model feasibility was 15.2%. GPT-5.5 hit 55.9%; most others were far worse. Hard RCPSP-SM was 0.3%. Even semantically equivalent reordering of the same constraints shifted hard-constraint violation rates beyond seed noise. The model is not invariant under “same spec, different wording,” which is exactly the spec-to-app non-determinism problem.[^2_2]

The solver-externalized pattern is the counter-architecture: the agent writes `z3` / MaxSAT / OR-Tools code, an exact solver returns an assignment, then a checker re-validates against the original constraints. The cited pipeline exceeded 80% acceptance on reasoning families where chain-of-thought and program-of-thought rarely produced a feasible solution.[^2_1]

## Imperative Search Versus Z3

Take a tiny on-call roster: 5 engineers, 5 shifts, one person per shift, at most two shifts each, no consecutive shifts, weekend preference as a soft objective.

An LLM writing imperative code invents a heuristic. Nested loops, greedy fill, random restart, maybe a half-finished backtracker. Two runs give two algorithms, both “reasonable,” often both infeasible, almost never optimal. The non-determinism is not just token noise; it is a different search procedure. Tamaton’s version of this: greedy calendar lookup is $O(M^N)$ in the worst case and commits early to locally free slots that globally fail.[^2_3]

The Z3 version is a translation of the spec:

```python
from z3 import *

engineers, shifts = range(5), range(5)
x = {(e, s): Bool(f"x_{e}_{s}") for e in engineers for s in shifts}

opt = Optimize()
for s in shifts:
    opt.add(Sum([If(x[e, s], 1, 0) for e in engineers]) == 1)
for e in engineers:
    opt.add(Sum([If(x[e, s], 1, 0) for s in shifts]) <= 2)
    for s in range(4):
        opt.add(Not(And(x[e, s], x[e, s + 1])))

opt.maximize(Sum([If(x[0, s], 1, 0) for s in (3, 4)]))  # weekends
assert opt.check() == sat
```

Same facts, different wording of the prompt, still the same constraint system if the encoding is faithful. Z3 then does the NP-hard part deterministically. Production scheduling usually wants OR-Tools CP-SAT rather than Z3, but the split is identical: LLM compiles English into a theory, the solver owns search.[^2_4][^2_1]

## What Non-determinism Remains

You have not eliminated the LLM. You have confined it to **encoding**. The remaining failure is “valid code, wrong problem”: a missed no-overlap, a hard constraint that should have been soft, an inverted preference weight. Solver-externalized work treats that as the only load-bearing bug, which is why verification against the original prompt is mandatory, not optional. LLM combinatorial output is not feasibility-safe by default.[^2_1]

That is still a huge reduction. Two encodings of “no consecutive shifts” that both type-check and both pass the independent checker produce equivalent optima (or an equivalent set of optima). Two imperative solvers of the same spec do not. Neuro-symbolic compliance work makes the same split for law: LLM → SMT, solver → consistency and minimal repair, with 86.2% correct SMT generation and >100× reasoning efficiency versus LLM-only.[^2_5]

## The Architectural Moral

Scheduling is the best teaching example because the compiler is visibly a theorem prover. The IR is variables, domains, hard constraints, soft weights, and an objective. The model’s job is semantic parsing. The solver’s job is search. If you let the model do both, you get SCHEDBench: infeasible, wording-sensitive, and untrustworthy even when it looks confident.[^2_2][^2_1]

For product design the rule is: if a human would reach for Z3, MiniZinc, CP-SAT, or a rules engine, do not let the agent write the algorithm. Let it write the model.

<span style="display:none">[^2_10][^2_11][^2_12][^2_13][^2_14][^2_15][^2_16][^2_6][^2_7][^2_8][^2_9]</span>

<div align="center">⁂</div>

[^2_1]: https://agentpatterns.ai/agent-design/solver-externalized-constraint-reasoning/

[^2_2]: https://arxiv.org/abs/2608.00991v2

[^2_3]: https://tamaton.com/blog/calendar/calendar-optimization-tamaton-s-constraint-solver-for-ai-scheduling

[^2_4]: https://www.mintlify.com/Z3Prover/z3/examples/constraint-solving

[^2_5]: https://arxiv.org/abs/2601.06181

[^2_6]: https://dl.acm.org/doi/pdf/10.1145/3763163

[^2_7]: https://context7.com/solverforge/solverforge

[^2_8]: https://arxiv.org/abs/2601.04675

[^2_9]: https://arxiv.org/abs/2603.06931

[^2_10]: https://arxiv.org/html/2604.05292

[^2_11]: https://www.alphaxiv.org/abs/2603.29088

[^2_12]: https://www.themoonlight.io/en/review/formaljudge-a-neuro-symbolic-paradigm-for-agentic-oversight

[^2_13]: https://www.alphaxiv.org/abs/2508.20340v3

[^2_14]: https://zesterapublications.com/journals/index.php/ijlah/article/view/569

[^2_15]: https://acingai.com/articles/llm-code-generation-formal-verification

[^2_16]: https://arxiv.org/html/2608.00991v2

