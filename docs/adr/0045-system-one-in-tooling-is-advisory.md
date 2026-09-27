# ADR 0045 — System One in developer and agent tooling is advisory

- **Status:** proposed
- **Date:** 2026-09-27
- **Amended:** 2026-09-28 — "local only" becomes "in-zone only"; the coding agent is itself outside the zone; offline
  optimisation of tooling questions is a proposal

## Context

The cheapest place to use a fast typed judgment is not the product; it is the tooling around it. This repository is
built largely by coding agents, and the agent tooling already has several places where a deterministic check stops short
of what a reviewer would want to know.

The facts, verified on 2026-09-27 against `ash_agent_tools` and its use here:

- **The laws judge is grep-tier and says so.** It reports hits in three tiers — `definite`, `likely`, `review` — and
  lists seven behavioural laws it has no detector for (authorize in every event handler, jobs are idempotent, comments
  are not commit messages, and others). The tiers carry the honesty: a `review` hit is a prompt to look, not a verdict.
- **`describe` reports a generic action's return type without its constraints**, though `validate` already shows the
  constraints of arguments.
- **Input validation casts against the real contract** without executing the action, and suggests corrections for
  unknown inputs by Levenshtein distance only — so `full_name` against a field called `name` is not caught.
- **Tool gaps are recorded as telemetry** (`[:ash_agent, :tool_gap]`) and triaged by hand.
- **The laws judge is not exposed as an MCP tool.**
- **Optional integrations degrade.** `ash_rules`, `ash_bpmn` and `ash_decisions` are optional dependencies of the tooling,
  detected at runtime; without them the tools return a structured error naming the missing dependency rather than
  crashing.
- **`ash_ai`'s `on_tool_start` is observe-only**, so a model-backed veto of an in-app agent's tool call is not possible
  without an upstream change. The agent *harness* — a coding agent's pre-tool-use hook, or an equivalent plugin — can
  call a local instrument directly, and Ollaya ships an MCP server (`ollaya mcp`) for exactly that.
- **CI gates on deterministic output.** `mix ast.check`, `mix ash.codegen --check` and `mix ash_enterprise.roadmap --check`
  all compare byte-for-byte or fail on a named condition. Wiring the laws judge into CI is planned and not yet done.

## Decision

**In developer and agent tooling, System One adds a separate, labelled, advisory signal. Deterministic reports stay
byte-identical and deterministic gates stay deterministic, unless an explicit, versioned promotion threshold says
otherwise. Where a declaration can decide, a model must not.**

**A separate field, never a changed one.** A model's contribution appears in its own field — `adjudications`,
`suggestions`, `rerank` — carrying the question hash, the model digest and the probability. The existing report is
unchanged whether or not an instrument is present, so every consumer that parses it today keeps working and every test
that pins it keeps passing.

**A new tier, `:model`, for honesty.** Detectors for the behavioural laws that are driven by a System One question
report in their own tier, below `review`. A `:model` hit is never `definite` or `likely`, and never counts towards
`clean?`.

**Promotion only by explicit threshold.** A caller may opt in to letting an adjudication change a verdict —
`promote_adjudicated: 0.97` on a review-tier hit, say — and the option names the threshold and the question version in
the report. There is no global switch and no default promotion. A promotion used in CI is a versioned setting in the
repository, reviewed like any other gate change.

**What the signal is for** — each an advisory use, none a gate:

- adjudicating review-tier law hits over their surrounding window ("is this argument derived from user input?");
- detectors for the behavioural laws that have none;
- semantic `did_you_mean` — the existing Levenshtein-based suggestion is unchanged and remains the contract; a
  model-ranked suggestion may appear only as a separate, labelled advisory field beside it, and its options are drawn
  from the action's real input contract (a `Choice` over it), so the model cannot invent a name;
- reranking search results on a miss;
- triaging tool-gap telemetry into alias, documentation fix or new default;
- a pre-flight check in the agent harness: deterministic allow and deny rules decide first. Only what they leave
  undecided gets a risk or intent score from System One, banded by a DMN table — and that band may only *raise* the
  request to a human "ask"; it may never allow a call outright and never silently deny one;
- offline optimisation of dev-tool question wording, whose output is a proposal
  ([ADR 0047](0047-learning-produces-proposals.md)).

**Tooling judgments are best-effort.** They may skip the ledger's must-record path ([ADR 0040](0040-record-dont-recompute.md));
when recorded, they are recorded under their own families, and they never share a calibration family with product
judgments.

**The same optional pattern.** The System One integration is an optional dependency of the tooling, detected at runtime.
With no instrument running, every tool behaves exactly as today.

**In-zone only.** Tooling judgments run against an instrument in the zone that holds the source they read. Source code
is not sent to a hosted instrument by default, and choosing to is the same disclosure decision as for product data
([ADR 0042](0042-in-zone-inference-leaving-the-zone-is-a-disclosure.md)). The coding agent that consumes these signals
is typically a hosted model itself, so what it reads has already left the zone: acceptable for source code and
synthetic fixtures, never for customer-confidential data.

## Does it consume ActorContext?

**No, and it has no need to.** This tooling runs in development and in CI over source code, manifests and telemetry,
not over tenant data; there is no actor and no grant to consult. The honest limit is the harness: a pre-tool-use hook
runs outside the application altogether, so a signal it produces governs nothing inside the app. That is why it is
advisory, and why the application's own policies stay the gate for anything an in-app agent does
([thesis 5](../manifesto/05-agents-are-users.md)).

## Consequences

**What this makes easy.** Review-tier noise shrinks without anything silently changing verdicts. The behavioural laws
get detectors at last, with their uncertainty visible. Agents get better corrections because the candidate set is the
real contract.

**What it makes hard.** Two signals where there was one, and the discipline of never letting the second leak into the
first. Local instruments have to be running for the signal to exist, which makes it uneven across machines — acceptable
only because it is advisory.

**What it forecloses.** A model silently flipping `clean?`. Model output merged into deterministic report fields. A
model-backed gate in CI without a named, versioned threshold.

## Reversal

Remove the optional dependency. Every report returns to exactly its current shape, because the deterministic fields
never changed; tools that surfaced model fields stop emitting them. Removing the harness hook is deleting one hook
configuration.
