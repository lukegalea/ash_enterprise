# ADR 0056 — The agent runtime is a separate public package, `ash_agent`, that the host instantiates

- **Status:** accepted, not built (2026-10-23)
- **Date:** 2026-10-23
- **Decided:** by Luke, 2026-10-22 (name, home and boundary)
- **Related:** [ADR 0009](0009-strangler-and-bpmn-are-first-party.md) (first-party platform extensions),
  [ADR 0055](0055-consequential-acts-are-governed-invocations.md) (governed invocation),
  [ADR 0057](0057-actions-declare-their-effects.md) (effects),
  [ADR 0058](0058-agent-quality-and-releases.md) (quality and releases)

## Context

[ADR 0055](0055-consequential-acts-are-governed-invocations.md) and the durable agent runtime need four resources
(invocation, agent version, run, step), one Spark extension and a few behaviours. Most of that is mechanism any Ash
application could use; tenancy, grants, approvals over ash_bpmn, sealing and triggers are this application's. Three
homes were considered: fragments incubated inside this repository behind a boundary test, a separate package from the
start, or waiting for an upstream agent in ash_ai.

Facts that bear on it, verified on 2026-10-23:

- **ash_ai already has the stateless loop.** ash_ai 1.3.0 ships tool approvals (`approve_tool_call` returning `:ask`,
  a resumable `:awaiting_approval` status, `resume/3`), message events from `stream/2` and `AshAi.Transcript`. This
  repository still locks 1.1.1 (`mix.lock`); the upgrade is separate work.
- **Upstream is exploring an agent of its own.** The ash_ai maintainer has an unmerged `agent` branch defining
  `AshAi.Agent`, a resource extension with one durable process per agent and compaction, depending on `durable_server`
  and `ekv`. It is not on a release and its design differs from rows-and-triggers durability.
- **The Hex name is taken.** `ash_agent` 0.3.1 on Hex (https://hex.pm/packages/ash_agent, read 2026-10-23) is an
  unrelated project, and it also defines a root module `AshAgent`. A host that installed both would not compile.
- **The `mix ash_agent.*` task namespace is taken in this repository.** The dev dependency ash_agent_tools defines
  `mix ash_agent.describe`, `.validate`, `.search` and fifteen more, and `AGENTS.md` tells every agent to use them.
- **The fragment pattern has precedent here.** `SystemOne.CalibrationRun` instantiates
  `AshJudgments.Calibration.Fragment` through `fragments:` on the platform base. The other house pattern, a library
  resource macro taking `base:` and `base_opts:` (ash_bpmn, ash_mdm, ash_discrete_business_events), keeps triggers,
  policies and the `postgres` block inside the macro's reach.
- **ash_bpmn depends on `phoenix_live_view`.** A package that depended on it could not stay free of Phoenix.

## Decision

**The runtime is a public package, `ash_agent` (app `:ash_agent`, root module `AshAgent`), in its own repository at
github.com/lukegalea/ash_agent. It ships Spark fragments, one extension, one validation and host behaviours. This
application instantiates every resource on `AshEnterprise.Platform.Resource` and supplies everything about tenancy,
authorization, approvals, sealing, audit and scheduling.**

The name is used regardless of the Hex package and of upstream's `AshAi.Agent`. The upstream branch stays context: the
package stays thin over ash_ai's loop and transcript so it can follow upstream, and talking to the maintainer is
useful but gates nothing.

### What the package declares and what the host supplies

| Concern | `ash_agent` declares | The host supplies |
|---|---|---|
| Resources | fragments `AshAgent.Invocation`, `AshAgent.AgentVersion`, `AshAgent.Run`, `AshAgent.Step`: attributes, calculations, actions with their changes and validations, the lifecycle as an AshStateMachine block, identities on non-tenant columns | the resource itself, on its own base; the `postgres` block, table and repo; host names (`AshEnterprise.Execution.Invocation` and so on) |
| Concurrency | fencing and budgets built from a changeset filter plus `optimistic_lock`, so they work with or without AshEvents | nothing |
| Tenancy | none; no action reads a tenant | multitenancy through the base; `use_tenant_from_record?` on every trigger |
| Authorization | no policies | the grant union, `extra_grants`, and which actions are self-service, human-only or machinery-only |
| Executing identity | `AshAgent.ExecutionIdentity` behaviour (`actor_for/1`), called at every claim | an implementation that builds a fresh `ActorContext` from grant rows |
| Approvals | `AshAgent.Approvals` behaviour; the `awaiting_approval` state and digest columns | an implementation over ash_bpmn `HumanTask`, and the trigger that applies decisions |
| Triggers | the trigger names its actions expect, and a template in `usage-rules.md` | the `oban` blocks: worker and scheduler names, queues, crons, `default_actor`, `actor_persister :none` |
| Sealing and audit | marks content attributes `sensitive?` | the AshCloak `cloak` block under the subject's erasure scope; AshEvents through the base |
| Effects | the `AshAgent.Effects` extension and its verifiers | declarations on its own actions ([ADR 0057](0057-actions-declare-their-effects.md)) |
| Governed targets | `AshAgent.Validations.Governed`, taking the host's invocation resource as an option | the option, on each governed target |
| Typed failure | `AshAgent.BusinessError` | mapping of integration errors to failure classes |
| Explorer | `AshAgent.Execution.Source` behaviour and the entry shape | the sources registry and the read-only projection |
| Telemetry | `AshAgent.OpenTelemetry`, one module that pins the GenAI attribute names | attaching it |
| Evaluation and releases | the fixtures-only executor (`mode: :eval` and `:shadow`) as part of the invocation fragment | suites, runs, case results and release manifests, as host resources ([ADR 0058](0058-agent-quality-and-releases.md)) |

### Boundary

The package depends on ash, spark, ash_ai, ash_state_machine and ash_oban. It does not depend on Phoenix, ash_bpmn,
ash_events, ash_cloak or anything from this repository. Its own CI enforces that: `mix deps.tree` lists no `phoenix*`,
and an xref check fails on any reference to `Phoenix*`, `AshEnterprise*` or `AshBpmn*`. Its fragments declare no
`multitenancy` block, no `oban` triggers, no policies, no relationship to a host resource, no identity naming a tenant
column, no `cloak` block and no actor-context type. Its test suite instantiates the fragments on a plain `Ash.Resource`
test base over Postgres, which shows a host other than this one can use them.

### Distribution and names

- **A git dependency only.** This repository consumes it as `{:ash_agent, github: "lukegalea/ash_agent"}` with a row in
  `docs/BLEEDING-EDGE.md`. There is no Hex publication while the Hex name belongs to another project, so that row's
  path to a Hex release is "none planned".
- **No mix tasks in the `ash_agent.` namespace.** They would collide with ash_agent_tools' tasks.
- **Public and generic.** The package, its docs and its examples carry no application-specific domain content. Worked
  examples use a synthetic clinic credentialing scenario.
- 0.x, with clean breaks allowed while this repository is its only consumer.

### What it does not own

Scope a durable agent runtime is sometimes given, and where it goes here instead:

| Concern | Where |
|---|---|
| Conversation memory | the run's append-only step journal; no separate memory store |
| Governed memory namespaces, embeddings and retrieval | deferred; pgvector is enabled and unused |
| Agent-to-agent delegation and multi-agent routing | refused for now ("never agent → agent", `lib/ash_enterprise/agents.ex`); a later amendment may allow bounded child runs with a toolset subset and a budget carved from the root run |
| Provider-specific integration packages | not part of this package; integrations reach governed invocation through the host |
| Evaluation suites and release manifests | host resources ([ADR 0058](0058-agent-quality-and-releases.md)) |
| Workers and process coordination | none; ash_oban generates workers from host triggers, and ash_bpmn stays the coordinator |

## Does it consume ActorContext?

Not directly, by design. The package names no actor-context type and builds no actor. It calls the host's
`ExecutionIdentity.actor_for/1` at every claim, and this host's implementation returns a fresh `ActorContext` from grant
rows ([ADR 0055](0055-consequential-acts-are-governed-invocations.md)). Every policy on the instantiated resources is
the host's, so the rules that checks never query and never use `forbid_if` for row access apply unchanged.

## Consequences

- The boundary is a dependency list, checked by the package's CI, rather than a convention inside one repository.
  Application-specific content stays out by construction.
- A second host can adopt the runtime by instantiating the fragments on its own base and implementing three behaviours.
- The cost is a public surface fixed early. It is kept small (four fragments, one extension, one validation, three
  behaviours, one telemetry module) and stays 0.x.
- Two changes now land in two repositories: the package first, then this repository moves its git lock.
- Anyone who also wants the unrelated Hex `ash_agent` cannot install both. That is accepted.
- If upstream `AshAi.Agent` lands with a different model, the overlap is resolved then: the package is thin over
  ash_ai's loop, so following upstream means replacing the loop driver, not the records.

## Reversal

While this repository is the only consumer: copy the fragments into `lib/ash_enterprise/execution/` as host modules,
drop the git dependency and its `docs/BLEEDING-EDGE.md` row, and keep the resources, tables and migrations, which
already belong to the host. Renaming the package (for example to reach Hex) is a module rename across the fragments
and the host's `fragments:` lists, with no data migration, because no table name comes from the package.
