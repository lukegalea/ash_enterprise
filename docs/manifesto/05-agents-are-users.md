# Thesis 5 — Agents are users

> The LLM gets the same action layer and the same policies as the web UI. Not a parallel path with parallel bugs.

## The mistake everyone is currently making

The standard way to add an AI assistant to an enterprise application in 2026 is to write a new service that talks to the
database, wrap some functions as tools, and hand them to a model. It ships in a week and it is a security incident
waiting for a date.

The reason is structural, not careless. That new service is a **second implementation of the application's rules**. It
has its own idea of who the user is, its own queries, and — critically — its own authorization, which was written under
time pressure by someone reasoning about prompts rather than about business units. Every rule enforced in the controller
layer has to be reimplemented, and the one that is missed is the one the model finds.

There is a well-known name for this shape: a confused deputy. The agent runs with more authority than the person asking,
and the only thing standing between a user and someone else's payroll data is that nobody phrased the question well
enough yet.

## Why this architecture does not have that problem

[Thesis 1](01-model-your-domain.md) established that Ash enforces policies at the **action layer**, not the transport
layer. That fact is what makes agents safe here, and it is worth being precise about the mechanism:

```
LiveView  ─┐
JSON:API  ─┤
GraphQL   ─┼─► Ash action ─► policies ─► data layer
Oban job  ─┤       ▲
MCP tool  ─┘       │
              one gate, no bypass
```

An `ash_ai` tool is not a new code path. It is a *declaration that an existing action may be called by a model*:

```elixir
defmodule AshEnterprise.Accounts do
  use Ash.Domain, extensions: [AshAi]

  tools do
    tool :assign_role, AshEnterprise.Security.UserRole, :create
    tool :list_users,  AshEnterprise.Accounts.User,     :read
  end
end
```

When the model calls `assign_role`, it invokes exactly the action the admin UI invokes, with the requesting user as the
actor, through exactly the same policy checks. If that person cannot assign roles in the UI, the model cannot assign
roles on their behalf — and nobody had to write an agent-specific rule to make that true.

The same holds for reads. Ash filters read actions rather than forbidding them, so a model asking "list all users"
receives the rows that *this actor* may see. Not a refusal, not a leak: a correctly narrowed result. Prompt injection
does not widen it, because the filter is applied below the prompt.

**This is the single strongest argument in this repository for the declarative approach.** The agent capability is close
to free, and it is safe for a structural reason rather than a vigilance reason.

## What still needs care

Structural safety is not total safety, and three things remain genuinely our problem.

**Tool scope is a decision.** Every action exposed as a tool is a capability handed to a probabilistic caller. Policies
bound what an actor may do; they do not bound what is *sensible* for a model to attempt unsupervised. Destructive and
bulk actions stay off the tool list unless there is a specific reason.

**Field exposure is asymmetric.** `ash_ai`'s `load` option can pull private attributes into a tool response even though
they are not filterable. That is useful and it is a real leak vector — `load` on a tool is reviewed as carefully as a
policy.

**Writes need a human.** Policies answer *may this actor do this*, not *did this actor actually ask for this*. Those
differ when an LLM is interpreting natural language, and the gap is where the confident-but-wrong mutation lives.

## Human-in-the-loop, rendered from the same metadata

The last point is what the agent console at `/agent` is for, and it is where `ash_a2ui` earns its place.

A request like *"assign the admin role to user XYZ"* does not execute. It pauses:

1. The model resolves the request to a concrete tool call — `assign_role` with specific arguments.
2. `AshA2ui.AgUi.pending_tool_call/4` suspends the run and emits an **A2UI surface** describing a confirmation form.
3. That surface is generated from the *resource's own metadata* — the same attributes, types, and constraints that
   produce the admin screen. Nobody hand-writes a confirmation dialog per tool.
4. The human sees the exact mutation, with real record names rather than UUIDs, and approves or rejects.
5. On approval the action runs — through the policies, into the audit log, with the human as the actor.

The audit entry records a human actor, because a human made the decision. The model proposed; it did not decide.

## Showing is not changing, and they must not share a shape

A console that only proposes mutations answers half the questions people actually ask it. *"Show me the legacy users"*
is not a change, and there is nothing for a human to decide by looking at the result: a table is filtered by the
viewer's own policies before a single row reaches the page. Putting a confirmation in front of it would not add safety —
it would subtract it, by teaching people that the confirmation is a thing you click past. **The confirmation on a write
is only worth reading because a read never asks for one.**

So `/agent` does three things, and they are deliberately three different shapes:

| Request | What happens | Waits for a human? |
|---|---|---|
| *"assign the Administrator role to dana@corp.example"* | resolved to a concrete mutation, held | **yes** |
| *"show me the legacy users"* | a **declared** surface is rendered | no |
| *"legacy users, just login and email, sorted by login"* | a surface is **composed**, validated, rendered | no |

The third is the interesting one, because it is where a model produces something that gets rendered. It does not
produce UI. It produces a **spec** — a resource name, field names, a sort — in the same vocabulary the compile-time DSL
uses. The server resolves every name in it against a host-configured allowlist and runs the *same verifier modules* the
DSL compiles with, over a synthetic DSL state. A spec naming a field that does not exist is refused with a structured
error, which is fed back rather than swallowed; it is never rendered blank.

Two properties follow, and both are structural rather than promised:

- **The allowlist is host configuration, not client input.** It gates the surface's resource and every context
  resource, so no request can compose its way to a table this application never meant to publish.
- **The resolved surface is held on the server**, keyed by its id, and client interactions are routed through it. A
  surface is never rebuilt from anything the client echoed back.

A composed table is also *live* when the resource it was composed over publishes notifications — the strangler read
model does, so a table the model designed thirty seconds ago updates itself when the old application writes. Nothing
about being designed at runtime makes a surface less able to keep up.

## Why A2UI rather than a chat transcript

A2UI (Google's open agent-to-UI payload spec) treats **UI as data, not code**. The server emits a description of a
surface; the client renders it from a catalog of components it already trusts. The model never emits markup and never
emits script — it references components that exist.

Two consequences matter here. The obvious one is safety: there is no path from model output to arbitrary rendering,
because the vocabulary is fixed by the client. The less obvious one is consistency: because `ash_a2ui` derives surfaces
from Ash resources, the agent's confirmation form and the admin screen are generated from the same source and cannot
drift apart. A field added to a resource appears in both.

It also means the query surface is server-enforced. `ash_a2ui`'s `query` block declares allowlists —
`search_fields`, `sortable`, `filters`, `page_size` — so a model cannot sort by a column it should not know exists.

## The three MCP surfaces, which are not the same thing

Worth separating, because they get conflated:

| Surface | Audience | Auth | Purpose |
|---|---|---|---|
| **Tidewave** (`/tidewave/mcp`, dev only) | the coding agent building this app | none, localhost | `project_eval`, `get_ash_resources`, SQL, version-pinned docs |
| **ash_ai dev MCP** (`/ash_ai/mcp`, dev only) | the coding agent | none, localhost | Ash-specific dev tools; upstream calls it experimental |
| **Production MCP** (`/mcp`) | external agents acting for a real user | **OAuth 2.1 or API key** | this application's actions, as tools |

Only the third is a product surface, and it is the one that must never be reachable without an actor. An MCP endpoint
with no actor is an unauthenticated API over your entire domain.

## Further reading

- `lib/ash_enterprise/ai/` — tool definitions and the agent runtime
- `lib/ash_enterprise_web/a2ui/` — surface definitions
- [thesis 3](03-authorization-is-data.md) — the policies all of this depends on
- [A2UI specification](https://a2ui.org/)
