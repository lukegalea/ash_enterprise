# Atelier copy — the marketing-facing package

*Ready-to-adapt copy drawn from the master narrative, written in the voice of the Enterprise
Atelier site.*

| | |
|---|---|
| **Status** | Copy source — adapt into `site/`, do not paste verbatim without checking the surrounding layout |
| **Audience** | Whoever is writing or editing the site, a deck, a README lede, or a conference abstract |
| **Primary source** | [`docs/narrative/declarative-semantic-platform.md`](../narrative/declarative-semantic-platform.md) |
| **Also grounded in** | [`docs/verification/`](../verification/), [`docs/rfc/semantic-manifest-v0.md`](../rfc/semantic-manifest-v0.md), [`docs/Has anyone made the argument for declarative progr.md`](../Has%20anyone%20made%20the%20argument%20for%20declarative%20progr.md) |
| **Rule** | Shipped things are present tense. Designs under review are labelled as such, in the same breath. §7 of the narrative travels with any excerpt — that is what the honest-limits sidebar is for. |

**Voice notes.** Short declarative sentences. Em-dashes over semicolons. Mono eyebrows in the
form `Section 0N — the <noun>`. Headings are sentence case and often end in a full stop. Never
claim a total where the rows are available. Lead with the caveat when there is one.

---

## 1. Hero framing

The shipped fold is `Say what the software must do. / Let the machine do the rest.` — that stays
canonical. These two are variants for contexts where the audience is known.

### 1A — Engineer-facing

> **Eyebrow** — Declare it once. Derive the rest.
>
> **Headline** — Let the model fill the form. *Let the compiler build the system.*
>
> **Subhead** — Ash Enterprise puts a declarative, typed, serializable artifact between the
> specification and the running system. An agent writes the declaration. A compiler derives the
> migrations, the policies, the audit trail, the REST and GraphQL surfaces, and the tool
> definitions — the same way, every time. Non-determinism is allowed in search. It is never
> allowed in the shipped system.

### 1B — Executive-facing

> **Eyebrow** — Enterprise-ready by inheritance.
>
> **Headline** — Move at the speed of agents. *Keep the controls you can defend.*
>
> **Subhead** — A small senior team and its agents can now build software as fast as they can
> describe it. The risk is that nobody can say afterwards what the system does, who authorized
> it, or what changed. Here, authorization, attribution and the audit trail are inherited by
> every part of the system, because there is no other kind of part to build.

**Where it goes.** 1A into the fold and the GitHub README lede. 1B into decks, the OG card, and
any page whose next click is `/proof/`.

---

## 2. The problem

> **Eyebrow** — Section 01 — the problem
>
> **Heading** — Same specification. Two incompatible systems.
>
> Give a language model the same product specification twice against an ordinary imperative
> stack and you get two working applications that disagree with each other: different error
> handling, different state model, different retries, different layering. That is
> non-determinism in the *process*, not in the tokens — and no amount of model quality fixes it,
> because the set of observationally similar imperative programs that satisfy a spec is
> enormous.
>
> The drift is worst across layers. One business rule — *a pending order may be approved by an
> admin* — has to hold in the UI, the context module, the changeset, the API and the tests.
> An agent will cheerfully invent a slightly different version of it in each, and every version
> compiles. You find out which one is authoritative during an incident.
>
> The cure is not a better prompt. It is a smaller artifact.

**Where it goes.** Ahead of Section 02 — the leverage, or as the opening beat of a talk.

---

## 3. Form, not architecture

> **Eyebrow** — Section 02 — the leverage
>
> **Heading** — The model fills a form. The compiler owns the how.
>
> A language model is a good semantic parser and a poor architect. So it is given the parser's
> job: turn an intent into a declaration that conforms to a schema. It does not choose a state
> model, a retry policy or a layering.
>
> Take the order-approval rule. Written imperatively, it is a fragment an agent must keep
> consistent in five places:
>
> ```elixir
> # The agent can invent a different version of this in every layer.
> if order.status == :pending and actor.role == :admin do
>   approve(order)
> end
> ```
>
> Declared, it is one fact, and the framework owns everything downstream of it — enforcement,
> the UI affordance, the API, the audit entry:
>
> ```elixir
> policies do
>   policy action(:approve) do
>     authorize_if actor_attribute_equals(:role, :admin)
>   end
> end
> ```
>
> Same specification. Fewer degrees of freedom. A deterministic remainder.

**Where it goes.** Immediately before the specimen plate, which then shows the same move at
resource scale.

---

## 3b. The extreme case (demo copy)

> **Heading** — If a human would reach for a solver, do not let the agent write the algorithm.
>
> Ask a model to *produce* an on-call roster — five engineers, five shifts, at most two each, no
> consecutive shifts, weekends by preference — and you have asked it to be a combinatorial
> solver. It is a bad one, and a differently bad one each run: nested loops here, a greedy fill
> there, a half-finished backtracker the third time. Published benchmarks put cross-model
> feasibility on scheduling problems at around 15%, and merely reordering the constraints in the
> prompt moves the violation rate.
>
> Ask it to *encode* the roster instead — variables, domains, hard constraints, soft weights, an
> objective — and it is doing the thing models are genuinely good at. Z3 or CP-SAT then does the
> NP-hard part, deterministically.
>
> One failure mode survives: valid encoding, wrong problem. A missed no-overlap. A hard rule
> that should have been soft. An inverted weight. That residual is the entire design problem,
> and it is why this platform spends as much effort on the checker as on the compiler.

**Where it goes.** A live demo, a talk, or an expandable aside on `/product/#workflow`. The
`ash_decisions` DMN story is the same shape in production dress.

---

## 4. The semantic layer

> **Eyebrow** — Section 0N — the semantic layer
>
> **Heading** — Every tool reads the same source of truth.
>
> Your editor, your agent, your graph explorer and your documentation each need to know what an
> action accepts, what it returns and why it might refuse. Normally each one re-derives that
> separately, and they drift.
>
> Ash already ships a versioned description of an application's runtime surface. What it does
> not carry is anything pointing back at source — no spans, no stable identifiers, no content
> digests, no provenance. Those absences are the difference between a description and a semantic
> layer. With them, a language server can underline one option rather than a block; an agent
> transcript can hold an identifier that survives a recompile; an indexer can ask *did this
> action change?* without diffing documents; and an error can name which `use` line injected the
> policy you are staring at.
>
> Semantic Manifest v0 is an RFC — a draft for review, deliberately additive, designed to land
> upstream rather than fork. Its discipline is that it adds those five things and nothing else.

**Where it goes.** `/product/` as a capability, and the doctrine page. Keep "RFC, draft for
review" attached; it is load-bearing.

---

## 5. Verification and compliance

> **Eyebrow** — Section 0N — the checker
>
> **Heading** — Catching confident silence.
>
> Most of the expensive failures in an enterprise system are not wrong answers. They are silent
> ones. A decision table with no matching rule returns null; null is not an error anywhere in
> the stack, so the evaluation records a success, the workflow promotes a null, and the gateway
> takes the default branch. Nothing reports a problem for months.
>
> Three designs are under review to close that class — publish-time analysis of decision tables
> for overlap and incompleteness, typing FEEL expressions against real Ash attributes, and a
> provenance envelope that records what ran, under whose authority, over what, as identifiers
> and digests rather than as values.
>
> The design choice we are proudest of is the refusal: a cell the analyzer has not been taught
> lowers to opaque, never to an approximation, and the report says out loud which tables it could
> not decide anything about. A checker that launders uncertainty is not worth having.
>
> **Shipped today:** the DMN compiler that refuses to publish, the hash-chained audit log, and
> the control map on `/proof/`, generated rather than asserted.

**Where it goes.** `/proof/`, under the existing disclaimer. Do not promote the three designs
to present tense until the code lands.

---

## 6. The dogfooding proof point

> **Eyebrow** — Section 0N — the loop
>
> **Heading** — This platform builds its own tooling with the tooling it builds.
>
> `ash_agent_tools` exists because agents working on this repository needed to interrogate Ash
> resources without executing them. It is now the reference implementation of the agent-facing
> contract — the thing an agent asks *what does this action accept?* before it calls anything.
>
> The semantic manifest RFC exists because four independent consumers — editor completion, an
> MCP tool for coding agents, a graph importer, and a documentation exporter — were each about
> to re-derive Ash semantics separately. It was written by agents reading vendored, read-only
> clones of the upstream projects, and every claim in it carries a file-and-line citation
> against a pinned version.
>
> The graph you use to understand the system is now fed by the same artifact the language server
> uses to complete it.
>
> Each turn makes the next turn cheaper, and each turn produces evidence rather than opinion.
> The corpus is the moat, not the code.

**Where it goes.** Doctrine, the README, and any investor or hiring conversation.

---

## 7. Honest-limits sidebar

> **Eyebrow** — What this is not
>
> **Heading** — The claims we decline to make.
>
> **There is no soundness claim for arbitrary Elixir.** The language is gradually typed and user
> callbacks run arbitrary code. The target is a typed declarative island with precise generated
> boundaries — not "prove every Ash application." Four honest strictness levels:
>
> | Level | Guarantee | Feasibility |
> |---|---|---|
> | 1 | DSL structural correctness — valid sections, options, allowed values | **High** |
> | 2 | Resource and action interface correctness — arguments, types, return shapes | **High to medium** |
> | 3 | Query and load correctness — relationship paths, calculations, filters, sorts | **Medium** |
> | 4 | Arbitrary callback and whole-program proof | **Low**, without restricting Elixir |
>
> Levels 1–3 are the target — plausibly the feel of a well-supported TypeScript ORM. Not a Rust
> or Gleam whole-program guarantee; getting there would mean a smaller language.
>
> **Declarative targets do not remove irreducible business logic**; escape hatches grow.
> **Schema bloat is the classic failure mode** — Kubernetes and Terraform both show YAML quietly
> becoming imperative. **The accepted surface is wider than the normalized one**, and both
> contracts are carried rather than one quietly claimed.

**Where it goes.** As a bordered sidebar beside the verification section, in the site's existing
"disclaimer first" pattern. It is a differentiator, not a disclosure — place it accordingly.

---

## 8. Tagline candidates

1. **Non-determinism in search. Never in the shipped system.**
   The narrative's own line. Engineer-facing, quotable, survives being repeated back.

2. **Say it once. Prove it everywhere.**
   Pairs the declaration with the evidence, which is the two halves of the product. Works over
   the OG card at display size.

3. **The compiler owns the how.**
   Shortest. Best as a section rule or a sticker; too terse to carry a page on its own.

**Recommendation.** (1) for engineer surfaces and the talk circuit, (2) for the executive deck
and the OG card. Keep (3) as furniture.
