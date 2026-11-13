# ADR 0026 — AI governance is disclosure, not a second authorization model

- **Status:** proposed
- **Date:** 2026-08-19
- **Narrowed 2026-09-28 by [ADR 0042](0042-in-zone-inference-leaving-the-zone-is-a-disclosure.md):** a model call
  to an instrument in the data's own declared zone is not an outbound disclosure; it is recorded in the judgment ledger.
  This record's disclosure logging applies to flows that leave a zone, and for customer-confidential data the per-tenant
  control is an opt-in rather than an opt-out. The rest of this record stands.
- **Amended 2026-11-13 — in-zone inference is ledgered, not disclosed.** The Decision below is scoped to calls that
  leave the data's zone; a call to an instrument in the same zone is recorded, not disclosed, and carries no tenant
  opt-out or opt-in. See the amendment at the end of this record.

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

**Treat an LLM call that leaves the data's zone as what it is — an outbound disclosure of tenant data to a
sub-processor — and record it exactly like every other privileged action.** A call to an instrument inside the
data's own zone is not that; the amendment below says what it is instead.

**Log prompt and response as audit events**, under the same tenant and the same correlation id as the
action that produced them. Not a separate AI log: the point of the correlation id is that "the user
asked a question, the model proposed a change, a human approved it, the action ran" reconstructs as
one operation, and a parallel log would make that impossible.

**Record the vendor, the model and the version** on each event. "Which model saw our data in March"
is a question with a specific answer, and it changes when a provider deprecates a version.

**Per-tenant control for a call that leaves its zone, enforced where the call is made** rather than in the UI. A
tenant with AI disabled must be unable to reach a model outside its zone even through the MCP endpoint, which means
the check belongs next to the client, not next to the button. For customer-confidential data the control is an
opt-in rather than an opt-out (amendment below).

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

## Amendment, 2026-11-13 — in-zone inference is ledgered, not disclosed

The decision above has not changed for the case it was written for. What has changed is that the case it was written
for is no longer the only one. [ADR 0042](0042-in-zone-inference-leaving-the-zone-is-a-disclosure.md) puts a local,
in-zone instrument at the centre of the default inference path, and the Decision above, read literally, would call
every one of those calls a disclosure to a sub-processor. It is not one: nothing leaves the boundary, no third party
sees the data, and there is nobody to opt out *of*. This section draws the distinction the Decision did not.

**The test is the zone, not the technology.** A call is judged by where the target runs relative to the zone the data
is in (the declared boundary of ADR 0042), not by what model or vendor it names.

| | Target in the data's own zone | Target outside every declared zone |
|---|---|---|
| Examples | a decision model served by a local runtime such as Ollaya; an in-zone generative runtime (llama.cpp, Ollama, vLLM) | a hosted model provider, a gateway such as OpenRouter, any model reached over a network the operator does not control |
| Is it an outbound disclosure to a sub-processor? | **No.** There is no sub-processor. | **Yes**, exactly as the Decision above states |
| What is recorded | One ledger record per call, under the same tenant and correlation id as the action that made it, naming the instrument and its pinned version | Prompt and response as audit events, vendor, model and version, under the same tenant and correlation id — the Decision above, unchanged |
| Tenant control | None needed; the zone declaration is the authority | Per-tenant control enforced next to the client: an opt-in for customer-confidential data, an operator acknowledgement for internal data, nothing for public or synthetic (ADR 0042) |

**For a same-zone call the disclosure obligation reduces to an audit-record obligation.** "Nothing records what a
model was sent" was the gap this record opened with, and it stays closed for in-zone calls: they are recorded, under
the correlation id, so "the user asked, the model proposed, a human approved, the action ran" still reconstructs as one
operation. What they do not need is the machinery that exists because a third party is involved — vendor disclosure,
tenant opt-out, per-flow authorization. This amendment does not decide how much a ledger row holds or how ledger volume
is managed; that is the judgment ledger's own record
([ADR 0040](0040-record-dont-recompute.md)), and the two are deliberately not restated in each other.

**Hosted calls are unchanged.** Every sentence of the Decision applies in full to a call that leaves the zone: prompt
and response logged as audit events, vendor, model and version recorded, per-tenant control enforced where the call is
made, content under ADR 0024's retention and erasure. That holds even if a deployment uses a hosted provider for
nothing but evaluation.

**"Local" is a per-zone concept, never a global switch.** A zone has a jurisdiction. A runtime in one regional stack is
outside every zone belonging to another region, so a call that is in-zone for one region's data is a disclosure for
another's. A deployment running separate regional stacks therefore classifies each call against the zone of the data it
carries; there is no single "local or hosted" setting for the whole deployment. Which zone a deployment starts with,
and its default posture, is the operator's decision and is not made by this record.

**A tenant can see its own posture.** Consistent with the disclosure philosophy of this record, a tenant is able to see
which zone its data is in, which targets are in that zone, and — for any call that left it — the disclosure log. For
cross-zone flows the tenant's opt-in or opt-out is the tenant's to set. The zone declaration itself is an operator's
statement about a deployment, not a statement about what any customer agreement permits, and no document should
present it as one.

**A hosted coding agent that reads tenant data is a cross-zone flow like any other.** A development agent, notebook or
query tool that sends what it reads to a hosted model is an outside-the-zone target under the table above, and the
disclosure rules apply to it in principle. The resolver next to the client cannot see that path, so it is closed by
role and by practice, as ADR 0042 records, rather than by a runtime check.

**Out of scope.** The default residency posture of a deployment, and the mechanism that resolves a profile to
*same zone* or *outside every zone*, are decided and built elsewhere (ADR 0042 and the profile resolver it describes);
this amendment states the doctrine they implement and must not drift from them.

### Does it consume ActorContext? — amended scope

**The answer is the same as above, and the amendment does not change it.** Inbound, a same-zone call runs as the
requesting actor, so the state reaching a local instrument is what that actor could already read. Outbound, a local
runtime is a service behind a network boundary like a hosted provider, and it cannot evaluate a grant either: it holds
no permission model to keep in sync, and removing it degrades a feature rather than breaking the application, so it
passes thesis 6 on the same two rules. Being in-zone relaxes the *disclosure* treatment; it adds no authorization
path.
