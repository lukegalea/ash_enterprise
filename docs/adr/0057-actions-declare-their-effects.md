# ADR 0057 — Every action exposed to an agent, an editor or a process declares its effects

- **Status:** accepted, not built (2026-10-23)
- **Date:** 2026-10-23
- **Related:** [ADR 0055](0055-consequential-acts-are-governed-invocations.md) (governed invocation),
  [ADR 0056](0056-the-ash-agent-package.md) (the package that ships the extension),
  [ADR 0046](0046-the-declaration-is-the-output-contract.md) (the declaration is the output contract)

## Context

Four pieces of code decide, each in its own way, whether an action is consequential. Verified on 2026-10-23:

| Classifier | Where | Rule |
|---|---|---|
| ACP command palette | `AshEnterprise.Acp.Commands.consequential?/2` | a hand-kept list of three resource and action pairs; everything else is not consequential |
| ACP extension methods | `AshEnterprise.Acp.ExtMethods`, `@writes` | four method names are writes |
| ash_acp tool kind | `AshAcp.Server`, `default_kind/1` (`deps/ash_acp/lib/ash_acp/server.ex`) | a `:read` action is `read`; anything else is `execute` |
| ash_a2ui canvas | `AshA2ui.Canvas.ObjectResolver`, `classify/1` | by action type |

They disagree, and none of them says what [ADR 0055](0055-consequential-acts-are-governed-invocations.md) needs to know
about a target: whether it writes outside this repository, whether it is safe to repeat, whether it needs approval and
from whom, and how to find out what happened when an acknowledgement is lost. The assistant also keeps a closed list
of seven proposal constructors (`lib/ash_enterprise/ai/proposal.ex`) because nothing else says which actions it may
propose.

Two public vocabularies cover most of it:

- **MCP tool annotations** (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`, with defaults when
  undeclared; https://modelcontextprotocol.io/specification/draft/server/tools, read 2026-10-21). The ash_ai version
  this repository locks (1.1.1) has no annotation support; upstream `main` has it on no release.
- **ACP `ToolKind`** (`read`, `edit`, `delete`, `move`, `search`, `execute`, `think`, `fetch`, `switch_mode`, `other`;
  the vendored schema in `deps/ash_acp/priv/acp_schema/schema.json`). The four MCP hints cannot produce `search`,
  `fetch`, `move` or `think`, so the kind has to be stated rather than derived.

## Decision

**One per-action declaration, the `AshAgent.Effects` Spark extension, states what an action does to the world. It
uses MCP's annotation vocabulary plus an explicit ACP kind, adds approval, intent and reconciliation, and is the only
source every surface reads.**

```elixir
effects do
  action :activate_credential,
    kind: :edit, read_only?: false, destructive?: false, idempotent?: true, open_world?: true,
    approval: :four_eyes, approver_role: :credentialing_committee, approval_expires_in: [days: 3],
    intent: :execute, reconcile_with: :lookup_activation, preconditions: [:subject]
end
```

| Option | Meaning |
|---|---|
| `kind` | the ACP tool kind, stated explicitly |
| `read_only?`, `destructive?`, `idempotent?`, `open_world?` | MCP's four hints, with MCP's defaults when left out |
| `approval`, `approver_role`, `approval_expires_in` | `:none`, `:confirm` or `:four_eyes`; who may approve; how long an approval lasts. [ADR 0055](0055-consequential-acts-are-governed-invocations.md)'s `request` reads these at runtime |
| `intent` | `:inspect`, `:propose`, `:approve`, `:test` or `:execute` |
| `reconcile_with` | a read action that finds an external effect by the invocation key, used when the outcome is unknown |
| `preconditions` | which inputs name records whose `version_number` is captured and rechecked |
| `compensate_with` | reserved; compensation is later work |

**Ours is authoritative.** The declaration on our own action is the truth. MCP hints imported from a foreign server are
untrusted input and never relax anything.

**"Read-only" is structural, not declared.** `read_only?: true` is accepted only on an Ash `:read` action. An agent
runs a tool inside its loop without an invocation only when it is an Ash `:read` action that is not open-world;
everything else goes through `invoke`. A hint can be wrong, and an open-world "read" is the usual way injected text
gets data out.

**Verifiers.** An action that is exposed as an ash_ai tool, an ACP command or a BPMN `ActionInvoker` entry and has no
declaration fails compilation when it is a governed target, and warns elsewhere until the inventory of exposed actions
is complete. A governed target with `approval` other than `:none` must name an `approver_role`.

**What it replaces.** The two host classifiers (`consequential?/2`, `@writes`) are replaced first. The two library
classifiers keep their defaults and gain optional, host-configured resolvers that read the declaration
(ash_acp's kind, ash_a2ui's consequence), so any other application using those libraries sees no change. The same
declaration drives ash_ai tool annotations (once ash_ai can carry them), ACP permission options, the confirmation tone
an A2UI surface uses, and which actions the assistant may propose, which retires the closed list of proposal
constructors.

## Does it consume ActorContext?

No. The declaration is compile-time DSL read with `Spark.Dsl.Extension`; it states what an action does, not who may
do it. Authorization stays in policies over `ActorContext`. The declaration's `approver_role` names who may be a
candidate for an approval task; whether a person holds that role is answered at claim time from a freshly built
context ([ADR 0055](0055-consequential-acts-are-governed-invocations.md)), never inside a policy check.

## Consequences

- One answer to "is this consequential, and how" across the assistant, ACP, A2UI, MCP and BPMN.
- A target's effects become part of its identity: [ADR 0055](0055-consequential-acts-are-governed-invocations.md)
  digests the declaration with the input schema, so changing it makes pending approvals stale.
- Declaring is per-action work, and the inventory of exposed actions has to be done before warnings become errors.
- The library resolvers are opt-in, so another application keeps today's defaults; that also means this repository
  carries two code paths in those libraries until the defaults are retired.
- Hints from foreign MCP servers still need a separate trust decision before any of their tools are offered.

## Reversal

Remove the extension from the resources that use it, restore the two host classifiers from history, and drop the
resolver configuration so the libraries fall back to their defaults. Governed invocation would then need approval
settings from somewhere else, so this reversal only makes sense together with reversing
[ADR 0055](0055-consequential-acts-are-governed-invocations.md).
