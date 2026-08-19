# ADR 0026 — AI governance is disclosure, not a second authorization model

- **Status:** proposed
- **Date:** 2026-08-19

## Context

"What data does your AI see?" is now a standard line on enterprise security questionnaires, and it is
usually answered badly — either with a reassurance that cannot be checked, or with a separate
AI-permissions system that immediately disagrees with the real one.

This repository is unusually well placed on the half that is normally hardest.
[Thesis 5](../manifesto/05-agents-are-users.md) settles it: an agent is an actor, `ash_ai` tools are
declarations that *existing* actions may be invoked, and the MCP endpoint requires a bearer key and
resolves the same `ActorContext` as the browser. A model therefore reaches nothing its user could not
reach unaided, and there is no agent-specific authorization path — which is precisely why there is no
agent-specific authorization bug.

What is missing is everything after that. Nothing records what was sent to a model, or what came back.
Nothing names which vendor or model version saw it. No tenant can decline. A questionnaire asking
"can we opt out" currently has no answer, and one asking "what left our boundary" has no evidence.

## Decision

**Treat an LLM call as what it is — an outbound disclosure of tenant data to a sub-processor — and
record it exactly like every other privileged action.**

**Log prompt and response as audit events**, under the same tenant and the same correlation id as the
action that produced them. Not a separate AI log: the point of the correlation id is that "the user
asked a question, the model proposed a change, a human approved it, the action ran" reconstructs as
one operation, and a parallel log would make that impossible.

**Record the vendor, the model and the version** on each event. "Which model saw our data in March"
is a question with a specific answer, and it changes when a provider deprecates a version.

**Per-tenant opt-out, enforced where the call is made** rather than in the UI. A tenant with AI
disabled must be unable to reach a model even through the MCP endpoint, which means the check belongs
next to the client, not next to the button.

**Content is subject to the same retention and erasure treatment as everything else in the log** —
which is [ADR 0024](0024-audit-retention-and-erasure.md), and is the reason these two are worth
sequencing together: prompts contain more personal data per byte than almost anything else recorded.

## Consequences

**What this makes easy.** Answering the questionnaire with a query. And an unglamorous operational
win: when a model proposes something wrong, the prompt that produced it is in the trail next to the
proposal.

**What it makes hard.** Volume — prompts and responses are large, and this multiplies audit storage in
a way ordinary events do not. And sensitivity: the log becomes a place personal data accumulates in
free-form text, which is a different retention problem from structured fields and an argument for
encrypting event content by default rather than opportunistically.

**What it forecloses.** Passing raw records to a model without them appearing in a trail. Which is the
intent.

## Does it consume ActorContext?

**Yes on the way in, and it cannot on the way out — which is the honest shape of the answer.**

Inbound, the agent is an actor and the tools are actions, so `ActorContext` governs every read a model
can cause. That is already true and already tested.

Outbound, an LLM provider is a service behind a network boundary with no ability to evaluate a grant.
The rule from [thesis 6](../manifesto/06-reversibility.md) applies literally: it receives only what
one actor was already entitled to see, it holds no authorization model of its own to keep in sync, and
removing it degrades a feature rather than breaking the application. A provider that required its own
copy of the permission model to function would fail the bar outright.

## Reversal

Deleting the logging is trivial. Deleting the *dependency* is the reversal that matters, and thesis 5
already arranged it: because tools are declarations over existing actions, removing AI removes the
`/agent` console and the MCP routes and leaves every action reachable exactly as before. Nothing in
the domain layer knows a model was ever involved.
