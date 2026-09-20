# The Declarative Semantic Platform

*Why this particular combination — declarative domain modelling, a serialized semantic layer,
typed boundaries, and agent planes — is worth more than the sum of its parts.*

| | |
|---|---|
| **Status** | Narrative source — the master document downstream READMEs, docs and site copy excerpt from |
| **Audience** | Engineers evaluating the stack; decision makers evaluating the bet |
| **Grounded in** | [`docs/manifesto/`](../manifesto/00-index.md), [`docs/rfc/semantic-manifest-v0.md`](../rfc/semantic-manifest-v0.md), [`docs/verification/`](../verification/), [`docs/Making Ash Spark First-Class in Elixir Tooling.md`](../Making%20Ash%20Spark%20First-Class%20in%20Elixir%20Tooling.md) |
| **Rule for excerpting** | Nothing here may be quoted downstream with its qualifications stripped. §7 is not optional trimming. |

---

## 1. The thesis

Ash Enterprise is a proof corpus for a claim that is now testable rather than merely arguable:

> **The reliable way to build software with language models is to let the model do semantic
> parsing, let a compiler do the search, and let a checker do the proving. Non-determinism is
> allowed in search. It is never allowed in the shipped system.**

Each of those three roles has a name in this repository.

- **The model is a semantic parser.** Its job is to turn a human intent into a declaration that
  conforms to a schema. It fills a form. It does not choose an architecture.
- **The framework is the compiler and the solver.** Ash turns one declaration into migrations, an
  API, policies, audit records and tool definitions. A DMN engine turns a decision table into an
  evaluation. A BPMN interpreter turns a diagram into durable execution. None of this varies run
  to run.
- **Verification is the checker.** Types at the generated boundary, policies compiled to
  enforcement, publish-time analysis of decision tables, and a provenance envelope that records
  what ran under whose authority. The checker's job is to reject the model's plausible-looking
  mistakes before they reach production.

That division is not a new idea in the abstract. What is new here is a working corpus in which
each role is a real artifact you can read, run and argue with.

## 2. The argument this rests on

The underlying claim — set out at length in
[*Has anyone made the argument for declarative programming…*](../Has%20anyone%20made%20the%20argument%20for%20declarative%20progr.md)
— is about **cardinality**, not about model quality.

Give a language model the same product specification twice against an imperative stack and you get
two working, incompatible implementations: different error handling, different state model,
different retry policy, different layering. That is non-determinism in the *process*, not merely in
the tokens. The set of observationally similar imperative programs that satisfy a given spec is
enormous.

The set of valid *declarations* of the same intent is very much smaller. An Ash action, a DMN
decision table, a BPMN diagram, a SQL query, a Terraform file — each has a constrained, checkable
encoding. And crucially, a deterministic compiler then maps that encoding to exactly one
implementation of the buttons, the policies, the retries and the persistence. Variance drops
because the space shrank and because the remainder is deterministic, not because the model became
a compiler.

The same argument taken to its limit is scheduling. Asked to *produce* a shift roster, a model is
being asked to be a combinatorial solver, and it is a bad one — and a differently bad one each
time. Asked to *encode* the roster as variables, domains, hard constraints, soft weights and an
objective, it is doing something models are genuinely good at, and Z3 or CP-SAT does the NP-hard
part deterministically. The remaining failure mode narrows to one thing: *valid encoding, wrong
problem*. A missed no-overlap constraint. A hard rule that should have been soft. An inverted
preference weight.

That residual failure mode is the whole design problem. It is why this platform spends as much
effort on the checker as on the compiler.

## 3. From argument to artifact

Every abstract move in that argument has a concrete counterpart in this program. The table is the
short version; the sections after it are the long one.

| Abstract move | Concrete artifact here | Status |
|---|---|---|
| Emit a schema, not an architecture | Ash resources on one platform base resource; `AshAgentTools.describe_action/2` and `validate_input/3` as the agent-facing contract | Shipped |
| Make the schema addressable and serializable | [Semantic Manifest v0 RFC](../rfc/semantic-manifest-v0.md) — spans, stable symbol ids, digests, provenance, layered on Ash's existing `Ash.Info.Manifest` | RFC, draft for review |
| Externalize the search to a solver | `ash_decisions` — DMN documents compiled to an immutable snapshot, evaluated by a native FEEL engine; `ash_bpmn` — BPMN compiled to a graph snapshot and run by a durable token interpreter | Shipped |
| Check the encoding, not just the syntax | [Publish-time decision verification](../verification/decision-validation.md) — overlap, incompleteness, and an explicit "could not decide" verdict | Design, for review |
| Type the boundary the model writes against | [FEEL ↔ Ash type integration](../verification/feel-type-integration.md), reusing the manifest's type vocabulary rather than inventing one | Design, for review |
| Keep the deterministic remainder deterministic | Generated migrations (`mix ash.codegen --check` gates CI); policies as an additive union of grants; derived REST, GraphQL and LLM tool surfaces | Shipped |
| Prove what actually ran | [The provenance envelope](../verification/provenance-envelope.md) — what ran, under whose authority, over what, as identifiers and digests rather than values | Design, for review |
| Give the tools the same semantics | Expert completion prototype (experimental Spark DSL candidates in the engine); Clarity ontology report and manifest importer | Prototype / merged in fork |

**On status.** Half of the rows above are designs under review, not shipped code, and this document
says so in the same table as the shipped ones. A narrative that blurs the two is marketing. The
argument is strong enough without it.

### 3.1 Schema, not architecture

The unit an agent works with here is not a file of Elixir. It is an action contract:
what the action accepts, what it requires, what it normalizes to, what it returns, and why it might
refuse. `ash_agent_tools` exposes exactly that as plain JSON-encodable maps and Mix tasks — no code
execution, no tool registry, no editor coupling. An agent composing a call can ask "what does this
accept?", submit a candidate input, and get back a validation report *before* anything runs.

This is the form-filling mechanic made literal. The model's output is checked against a schema in
milliseconds. Compare that to the alternative — generating procedural code, compiling it, and
reading it to find out whether the business rule survived the trip through the LiveView, the
context module, the changeset and the API layer.

### 3.2 A serialized semantic layer

The manifest is the part that makes the schema *portable*. Ash already ships `Ash.Info.Manifest`: a
versioned IR of the application's runtime surface, with a JSON serializer and a Mix task. What it
does not carry is anything pointing back at source — no spans, no stable identifiers, no content
digests, no provenance chain.

Those five absences are the difference between a description and a semantic layer. With them, a
language server can underline one option rather than a block; an agent transcript can hold a symbol
id that survives a recompile; an incremental indexer can ask "did *this* action change?" without
diffing whole documents; and a diagnostic can say *which* `use` macro injected the policy the user
is confused about — a user-shaped error instead of a framework-shaped one.

The RFC's defining discipline is that it adds those five things and nothing else. An earlier
revision proposed a parallel manifest and was withdrawn; §3 of the RFC is a field-by-field audit of
what Ash already models, and §11 lists every place the schema was collapsed onto Ash's existing
shapes rather than duplicating them. Six type kinds were withdrawn because Ash already expressed
them. This is the correct posture for work intended to land upstream, and it is also the correct
posture for a semantic layer generally: one vocabulary, or the translation layers eat the benefit.

### 3.3 Solver-externalized reasoning

`ash_decisions` is the Z3 argument in production dress. A DMN document is compiled — really
compiled, with refusals — into an immutable snapshot before it can be published. The compiler
already proves the XML parses, that every boxed expression is a decision table or literal
expression, that the hit policy is not one where rule *order* is semantically significant, that
every information requirement resolves and the DRD is acyclic, and that every literal FEEL
expression parses within bounds.

The verification design then closes the three holes that compiler leaves, and it is instructive
that all three fail *silently*:

- **Overlap.** A `UNIQUE` table whose rules can both match is a runtime error discovered per case,
  per tenant, months after publish.
- **Incompleteness.** A table with no matching rule and no default returns `null` — and `null` is
  not an error anywhere in the stack. The evaluation row records a success, the business rule task
  promotes a null signal, and the gateway after it takes the default branch. Nothing reports a
  problem.
- **Unverified input entries.** A typo in a cell is found the first time a case hits that row.

The design's most important choice is the `{:opaque, text}` sink. A cell the recognizer has not
been taught lowers to opaque — never to an approximation — and the report says out loud which
tables it could not decide anything about, rather than reporting silence as success. That is the
checker refusing to launder uncertainty, which is precisely the discipline that makes a checker
worth having.

### 3.4 The deterministic remainder

The parts of this system that must not vary do not vary, and they do not vary because a compiler
owns them.

Change a resource, run `mix ash.codegen`, and the migration is derived as a diff against the
resource snapshots; `mix ash.codegen --check` gates CI, so schema drift is a build failure rather
than an incident. Declare a policy and the enforcement compiles out of it — and because the
authorization model is a pure union of grants with no deny rules, adding a grant can only ever
widen access, which means policies compose without order-dependence. The same resource definition
produces the REST surface, the GraphQL schema, the admin UI, the audit trail, and the LLM tool
definitions. One declaration; one implementation of each.

## 4. The agent plane

Thesis 5 of the manifesto is *agents are users*. An LLM working in this system goes through the
same action layer, the same validations and the same policies as the web UI. It is not a parallel
path with parallel bugs, and it is not a privileged one.

This matters more than it sounds. The standard failure of agent integration is a second door: a
tool surface that bypasses the checks the UI performs, because writing the checks twice was
tedious. Here the checks are not written twice because they are not written at the boundary at
all — they are declared once on the resource and derived onto every surface. The agent inherits
authorization for the same reason the CSV export does.

## 5. The dogfooding loop

The program has a structural property worth naming plainly, because it compounds.

The platform is building its own tooling with the tooling it builds. `ash_agent_tools` exists
because agents working on this repository needed to interrogate Ash resources without executing
them — and it is now the reference implementation of the agent-facing contract. The semantic
manifest RFC exists because four independent consumers (Expert completion, an MCP tool for coding
agents, a Clarity graph importer, and a documentation exporter) were each about to re-derive Ash
semantics separately; it was written *by* agents reading vendored, read-only clones of Spark and
Ash, and grounded with file-and-line citations against pinned versions. The Clarity fork now
imports manifest symbols as span- and provenance-rich vertices, so the graph you use to understand
the system is fed by the same artifact the language server uses to complete it.

Each turn of that loop makes the next turn cheaper, and — this is the part that is hard to
replicate — each turn produces *evidence*. The spike that checked whether Spark's ElixirSense
plugin fires under Expert produced a results directory, not an opinion. The corpus is the moat, not
the code.

## 6. What this is worth to someone deciding

Three things, stated without hedging because they are defensible.

**Variance in the spec-to-system path drops, measurably.** Not because the model is more reliable,
but because the artifact it produces is smaller, checkable in milliseconds, and compiled rather
than interpreted by convention.

**The failure modes move from silent to loud.** The bulk of the verification work in this program
is not about catching wrong answers; it is about catching *confident silence* — a decision table
that returns null, a FEEL type error folded away, an audit trail whose join key is missing from one
leg. Silent failure is what makes enterprise systems expensive to operate.

**Auditability is a product of the architecture, not a tax on it.** The provenance envelope records
what ran, under whose authority, over what, and with what result — as identifiers and digests,
never as values — which is how you keep an evidentiary trail without accumulating a liability of
customer data in an unretained table.

## 7. What this is not, stated plainly

Any downstream excerpt that drops this section is misrepresenting the work.

**There is no soundness claim for arbitrary Elixir.** Elixir is gradually typed, dynamic escape
hatches are intentional, Ash accepts runtime-configured types and extensions, and user callbacks
execute arbitrary code. The target is a **first-class typed declarative island with precise
generated boundaries** — not "prove every Ash application." The four honest strictness levels, from
[*Making Ash/Spark First-Class in Elixir Tooling*](../Making%20Ash%20Spark%20First-Class%20in%20Elixir%20Tooling.md):

| Level | Guarantee | Feasibility |
|---|---|---|
| 1. DSL structural correctness | Valid section/entity/option, allowed values, required options, extension compatibility | **High** — Spark already owns most of the metadata and validation |
| 2. Resource/action interface correctness | Attribute access, argument names and types, required inputs, return/error/page shapes | **High to medium** — needs precise generated contracts and accepted-input modelling |
| 3. Query/load correctness | Relationship paths, calculations, fields, filters, sorts, load-dependent field presence | **Medium** — needs a first-class load/query type algebra and probably bounded refinements |
| 4. Arbitrary callback/program proof | All callbacks, dynamic dispatch, runtime extension choice, external side effects | **Low** without restricting Elixir or moving logic into a statically typed language |

Levels 1–3 are the target. That can plausibly exceed typical dynamic-framework tooling and feel
comparable to a well-supported TypeScript ORM. It is not Gleam's or Rust's whole-program guarantee,
and getting there would mean restricting the programming model.

**Declarative targets do not eliminate irreducible business logic.** Application-specific behaviour
still needs improvisation, and that is exactly where a model earns its keep. Escape hatches are
real and they grow.

**Schema bloat is the classic failure mode.** Kubernetes, Terraform and dbt all demonstrate YAML
quietly becoming an imperative language. The defence is constrained scope plus explicit imperative
exits, not an infinite schema — and it is a language-design problem, not an LLM problem.

**The accepted surface is wider than the normalized one, and we say so.** A generated boundary that
casts its input genuinely accepts more than its normalized type describes. Claiming otherwise would
be the most tempting available lie, and both the manifest RFC and the FEEL typing design refuse it
structurally by carrying both contracts.

**Much of the verification layer is design, not shipped code.** See the status column in §3.

---

## The one-paragraph version

Ash Enterprise takes a specific architectural bet: put a declarative, typed, serializable
intermediate representation between the specification and the running system; let the language
model populate it; let a compiler own everything that should not vary; and let a checker prove the
things that fail silently. The manifest makes that IR addressable. The policy model makes
authorization additive. DMN and BPMN move combinatorial and procedural reasoning out of prose and
into engines that can be analysed before they run. The provenance envelope records what actually
happened as evidence rather than as data. And the whole apparatus is being built by agents using
the tools it produces, which is both the fastest way to find out whether the bet is good and the
reason the corpus is hard to copy. Non-determinism is allowed in search. It is never allowed in the
shipped system.
