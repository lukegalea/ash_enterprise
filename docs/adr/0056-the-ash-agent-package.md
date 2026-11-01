# ADR 0056 — The agent runtime is a separate public package, `ash_agent`, that the host instantiates

- **Status:** accepted (2026-10-23); agent versions built (2026-10-31), see
  [Built](#built-2026-10-31-agent-versions)
- **Date:** 2026-10-23
- **Decided:** by Luke, 2026-10-22 (name, home and boundary)
- **Amended:** 2026-10-29 — dependency versions and the Phoenix edge; see
  [Amendment](#amendment-2026-10-29--dependency-versions-and-the-phoenix-edge). 2026-10-31 — the prompt format (D7) and
  where a version is published; see [Built](#built-2026-10-31-agent-versions)
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
  a resumable `:awaiting_approval` status, `resume/3`), message events from `stream/2` and `AshAi.Transcript`. When
  this record was written the repository still locked 1.1.1; it now locks ash_ai 1.4.1 (`mix.lock`, corrected
  2026-10-29).
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
ash_events, ash_cloak or anything from this repository. Its dependency tree allows exactly one Phoenix edge, ash_ai ->
ash_json_api -> phoenix (see the [amendment](#amendment-2026-10-29--dependency-versions-and-the-phoenix-edge)). Its
own CI enforces that: `mix deps.tree` reaches no `phoenix*` package by any other route, and an xref check fails on any
reference to `Phoenix*`, `AshEnterprise*` or `AshBpmn*` from the package's own code. Its fragments declare no
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

## Amendment, 2026-10-29 — dependency versions and the Phoenix edge

- **ash_ai and req_llm are upgraded wherever they are needed.** Decided by Luke on 2026-10-22. This repository, the
  first-party libraries and the package move to the ash_ai and req_llm releases the runtime needs when they need them.
  A library's merge is not held for a downstream consumer's release milestones: library pull requests stay additive
  where they can, merge on green CI, and consumers whose code calls a changed API hear about it before the merge.
- **The tree allows one Phoenix edge.** Found on 2026-10-27 while building the package: ash_ai (1.3 and later) depends
  on ash_json_api, which depends on phoenix unconditionally, so a package that uses ash_ai cannot keep Phoenix out of
  its dependency tree. The boundary check therefore allows exactly the edge ash_ai -> ash_json_api -> phoenix, and still
  fails on any other route to a `phoenix*` package and on any reference to `Phoenix*` from the package's own compiled
  code. The Boundary section above is corrected to say so. Making ash_json_api's phoenix dependency optional upstream
  would remove the edge.
- **The lock.** Context said this repository still locked ash_ai 1.1.1, which was true on 2026-10-23. It now locks
  1.4.1.

## Built, 2026-10-31: agent versions

- **The fragment.** `AshAgent.AgentVersion`: `key` and `version` (unique together), `instructions`, `model_profile`,
  `toolset` (each target as `"Resource.action"` with its target digest, the one invocations use), `limits`
  (`max_steps`, `max_tool_calls`, `deadline` in seconds, `token_budget` in tokens, `max_repairs`), `output_type`,
  `source` (`:code` or `:authored`), `baseline_id`, `content_hash`, and the publish-time `authority` and
  `requesterless`. Lifecycle `draft → published → retired`, one way. Versions are rows, not temporal (decision D11,
  as for process and decision definitions under [ADR 0049](0049-temporal-resources-are-the-validity-substrate.md)).
- **Agents declared in code.** `use AshAgent.Agent` with the key, instructions, model profile, tools as
  `{resource, action}`, limits and output type. `register_from_code` is the code sync: it returns the key's latest
  version when the content hash is unchanged and writes nothing, and otherwise writes the next version as a draft.
  The content hash covers each tool's digest, so a changed tool also makes a new version.
- **The prompt format (decision D7): plain text.** The decision was to adopt a logic-less subset of dotprompt only if
  it fit cleanly after reading the specification, and otherwise to use plain text with `Transcript.fingerprint` as
  identity. Read on 2026-10-31 (https://google.github.io/dotprompt/reference/frontmatter/ and
  https://google.github.io/dotprompt/reference/template/): the template language is Handlebars-based, and an
  implementation MUST support the documented Handlebars features, `#if`, `#unless` and `#each` among them, and the
  helpers `json`, `role`, `history`, `media` and `section`. The specification defines no logic-less subset or
  conformance level, so a subset would not be dotprompt, and there is no Elixir renderer to conform to. The
  frontmatter's useful fields (`model`, `tools`, `input`, `output`, `config`) are already columns of the version.
  So `instructions` are plain text with no template language. A version's identity is its `content_hash` (SHA-256
  over RFC 8785 canonical JSON of its content); what a model was shown at a step is identified by
  `AshAi.Transcript.fingerprint/2` over the instructions and the tools the step offered, recorded on the step by the
  run.
- **Publishing is a governed invocation.** The fragment's `apply_publish` refuses a draft with a toolset target that
  declares no effects (read through `AshAgent.Effects.Info`, via `AshAgent.Invocation.Target.resolve/1`), or whose
  declaration or input schema changed since the draft was written, or with a limit unset. Here it is a governed target
  ([ADR 0055](0055-consequential-acts-are-governed-invocations.md)): four eyes, an administrator other than the
  requester, expiring after seven days. `request_publish` checks the draft first, so a draft that cannot be published
  opens no approval, and then asks through `invoke`; there is no second approval path. The approval binds the draft's
  `version_number`, so a draft revised while it waits goes stale. This application also requires the in-zone model
  profile ([ADR 0042](0042-in-zone-inference-leaving-the-zone-is-a-disclosure.md)) and, for an automation authority, a principal this build
  declares (`Execution.Validations.Publishable`). Both publish actions are `changes_authority`: an automation
  principal never publishes an agent.
- **Authority (decision D13).** A version's runs act as the requester unless the publisher names an automation
  principal, as an argument of the request the approver approves. `requesterless` is allowed only with an automation
  authority, and only at publish.
- **Pinning and drift.** A run pins a version's id and calls `AshAgent.AgentVersion.Definition.check_pinned/1` before
  each step: the version must be published or retired, and every toolset target must still have the digest it had
  when the version was written. Otherwise the run fails closed with `AshAgent.AgentVersion.DefinitionDrift`
  (`:definition_drift`). Publishing version 2 changes nothing about version 1, so a run pinned to it carries on;
  `latest_published` is what a new run starts on.
- **Where a version is published: in a tenant, not in the platform organization.** The plan placed code-declared
  agents in the platform organization as baselines that tenants fork, the way processes and decisions are
  ([`Process.Resolver`](../../lib/ash_enterprise/process/resolver.ex)). That organization has no people, so nobody
  there could be the four eyes, and process baselines are published by a deploy task rather than approved. Agent
  baselines are registered there from code (as the `seed` system actor) and never published there. A tenant copies
  the latest one with `fork_for_tenant`, which reads it through `Resolver.agent_baseline/1`, the named cross-tenant
  read, records it as `baseline_id`, and writes nothing when the tenant already holds that content. The tenant then
  publishes its copy under its own administrators' approval, and its runs pin the copy. Who a run acts as, and whether
  it may run with no requester, are tenant choices, which is where automation principals and their start grants
  live.
- **Not built here.** The boot-time sync that registers every declared agent into the platform organization: no
  agent is declared in code yet, so it lands with the first one (the run and assistant tickets). Tenant-authored
  agents beyond `create_draft` and `revise_draft` wait for decision D16.
- **Tests.** Package: `test/ash_agent/agent_version_test.exs`. Here:
  `test/ash_enterprise/execution/agent_version_test.exs`.

## Built, 2026-10-31: agent runs

- **Rows and a trigger, not a process.** `AshAgent.Run` (here `Execution.Run`, table `exec_agent_runs`) is one run of
  a pinned agent version and is its own checkpoint: `step_seq` is the pointer and `lease_epoch` the revision.
  `AshAgent.Step` (here `Execution.Step`, `exec_agent_steps`) is its journal, one row per message, appended only by the
  run's `record_step` inside its fenced transaction and never changed. Steps are not audited (the content-ledger
  pattern of `AI.ModelCall`); the run transition that commits with each one is.
- **One `:step` job is one model call.** `claim_step` takes the next epoch under `optimistic_lock(:lease_epoch)`, so
  a duplicate job loses before any model call, and checks the deadline, drift of the pinned version, the step and
  tool-call limits and the token budget. The step then rebuilds the executing actor from grant rows
  (`Execution.Identity.actor_for/1` with the run), the conversation from the journal and the tools the version offers
  that actor, and calls ash_ai's tool loop once, with no transaction open, through
  `Execution.AgentRuntime`: the in-zone profile only, through `AI.Models.GuardedReqLLM`, so each call is a `ModelCall`
  whose caller is `run:<run id>:<step seq>` and a repeated call shows under the same name. Each message is recorded
  under the fence: `record_step` is filtered on the epoch and on the `step_seq` its caller read, so an append from a
  superseded worker or a stale copy changes nothing.
- **Tool calls.** Only Ash `:read` actions whose declaration does not reach outside run in the loop, as the executing
  actor. Every other call stops the loop and becomes an invocation keyed `run:<run id>:<step seq>:<tool call id>`,
  requested as the person who started the run (`Identity.requester_for/1`) with the run as its parent
  (`Validations.OwnsParent` accepts only a run the requester started), in the same transaction as the step that made
  the call. A step repeated after its worker died reads each call's invocation by that key and its recorded result;
  nothing runs twice.
- **Who may start one (decision D13).** `start` is self-service, and `Identity.run_principal/3` refuses anyone without
  the agent's start grant ([ADR 0043](0043-automation-authority-is-a-grant.md)). The run
  executes as the version's publish-time authority: the person, or the named automation principal acting for them.
  Either way the grant is read again at every step, every tool call the run requests and every claim of one, so a
  revoked start grant fails the run, or the call, as `:denied` before another model call or target runs.
  Requesterless runs are still refused: nothing starts a run with no person yet.
- **Wake-up and recovery.** `needs_step` is derived over the run's invocations, never counted.
  `AshAgent.Run.Changes.Wake` on `Execution.Invocation` enqueues `:step` when one of a run's invocations finishes;
  the `:step` sweep finds a lost wake-up and `:recover` re-queues a running run whose lease expired. Both triggers run
  on their own queue, `:agent_runs`.
- **Output.** A final answer is cast to the version's `output_type`; one that does not cast gets up to `max_repairs`
  repair turns, then the run fails as `:rejected` (`output_uncastable`).
- **Cancellation.** `request_cancel` (by grant) cancels the run and its invocations that have not started; an
  executing one records the request; nothing done is undone.
- **Sealing.** `input`, `output` and each step's `parts` are sealed under the subject's erasure scope, as an
  invocation's arguments are (built 2026-11-01, AGT-32; see "Erasure of a run" below).
- **Not built here.** Budget reservation across a root run and `extend` (AGT-30), waiting on a person (AGT-31), the
  assistant on runs (AGT-33), requesterless starts.
- **Tests.** Package: `test/ash_agent/run_test.exs`. Here: `test/ash_enterprise/execution/run_test.exs`, and in the
  durability tier `run_resume_test.exs` (F1), `wakeup_test.exs` (invariant 9) and `cancellation_test.exs`
  (invariant 5).

### Erasure of a run (built, 2026-11-01)

A clinician who asks to be erased while audit retention applies must be erased from every copy an agent run made of
them: its input and answer, each journal message, each tool call's arguments and result. One scope seals them all,
so one shred reaches them all ([ADR 0024](0024-audit-retention-and-erasure.md)).

- **A run names what it is about.** `start` takes `subject_type` and `subject_id` (the package reads the record as the
  starter, so a record they cannot read is refused like one that does not exist, and leaves it in the changeset
  context as an invocation's `request` leaves its subject). `Changes.SealingScope` seals the run under that record's
  `erasure_scope_id` when it has one, and otherwise, as before, under the requester's own scope.
- **Its steps and its tool calls follow it.** A step takes the run's scope (`Changes.FromRun`). A tool call takes the
  scope of the record its target acts on when that record has one (ADR 0055's rule), and otherwise its run's: the
  model wrote the arguments from what the run was given and read. A direct request with neither keeps the
  requester's scope.
- **Shredding reports, it does not delete.** Once the scope is shredded, `Step.parts`, `Invocation.args` and
  `result`, and the run's `input` and `output`, read as `AshEnterprise.Erasure.Shredded`, and `Step.recorded?` and
  `Invocation.recorded?` are false. The rows, their order in the journal, their transitions and the audit hash chain
  stay; the audit log only ever held ciphertext or nil for these fields (spike S2), so the chain still verifies.
  Nothing new lands under a shredded scope, so a run about an erased subject cannot start.
- **One scope per row.** A run about one subject that acts on a record sealed under another seals that call under
  the record's scope; content that mentions several people lives under one of them, as the scope model says.
- **Tests.** `test/ash_enterprise/execution/run_erasure_test.exs` (F11).
