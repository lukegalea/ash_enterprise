# ADR 0055 — Every consequential act is one governed invocation

- **Status:** accepted (2026-10-23); the invocation record, `invoke`, the lease and the `:execute` handoff built
  (2026-10-29); approvals, reconciliation, typed business errors and the automation principal not built
- **Date:** 2026-10-23
- **Amended:** 2026-10-29 — the coding-agent bridge; see
  [Amendment](#amendment-2026-10-29--the-coding-agent-bridge)
- **Related:** [ADR 0015](0015-approvals-stay-in-ash.md) (approvals stay in Ash),
  [ADR 0043](0043-automation-authority-is-a-grant.md) (automation authority is a grant),
  [ADR 0052](0052-self-service-actions.md) (self-service actions),
  [ADR 0056](0056-the-ash-agent-package.md) (where the runtime lives),
  [ADR 0057](0057-actions-declare-their-effects.md) (the effects declaration)

## Context

An agent's tool call, a BPMN service task and an integration call all end in an Ash action that changes something.
Today each reaches that action by its own path, and none of the paths records the act as a thing that can be
retried, approved, fenced or explained afterwards. Verified against `main` on 2026-10-23:

- **Five approval mechanisms, none bound to the request.** The coding-agent bridge's `Agents.ToolGate` approves one
  `ToolInvocation` row but passes the port only an approved flag and the request id
  (`lib/ash_enterprise/agents/tool_gate.ex`). ACP approvals live in ETS and do not survive a restart
  (`lib/ash_enterprise/acp.ex`). The assistant's proposals are rebuilt and re-authorized as the person
  (`lib/ash_enterprise/ai/proposal.ex`, `assistant/proposal_settlement.ex`). Morning briefs have `BriefDecision`.
  Process approvals are ash_bpmn `HumanTask`s. None stores a digest of what was approved or checks, when the act
  runs, that the arguments, the subject and the approver's authority are still what they were.
- **The production MCP endpoint writes without approval.** `/mcp` exposes `assign_role`
  (`lib/ash_enterprise/security.ex`, `lib/ash_enterprise_web/router.ex`), which runs as soon as the model calls it,
  against [thesis 5](../manifesto/05-agents-are-users.md)'s "writes need a human".
- **A service task's failure is untyped.** `AshBpmn.ActionInvoker.invoke/2` returns `{:error, term()}`, so the engine
  cannot tell a business refusal from a timeout, which is why ash_bpmn refuses error-boundary events. The host
  invoker runs every service task as `SystemActor.process()` (`lib/ash_enterprise/process/action_invoker.ex`) and
  leaves idempotency to each target action.
- **A standalone approval's callback is outside its transaction.** `AshBpmn.decide/2` commits the task and only then
  calls the `on_complete` action, through the invoker, as the process actor (`deps/ash_bpmn/lib/ash_bpmn.ex`). A crash
  between the two leaves the task decided and the subject untouched, and a person-only policy on the callback is never
  evaluated. Nothing in the host uses that path yet.
- **AshEvents refuses atomic updates on audited resources.** It sets `require_atomic?: false` on every update and
  destroy and errors on a changeset that carries atomics
  (`deps/ash_events/lib/events/transformers/wrap_actions.ex`, `action_wrapper_helpers.ex`). A changeset filter and
  `optimistic_lock` still reach the data layer's `UPDATE … WHERE`, so those are the primitives an audited lease can
  be built from.

## Decision

**Every consequential act runs through one governed invocation: a row with a stable logical key, a keyed digest of
its arguments, a lease epoch that fences stale workers, an approval bound to the exact request, and a typed outcome
that includes "outcome unknown". The authority it runs with is rebuilt from grant rows when it executes, never carried
over from when it was proposed.**

### The row

The host's `Execution.Invocation` resource, instantiated from the `AshAgent.Invocation` fragment
([ADR 0056](0056-the-ash-agent-package.md)), holds:

| Group | What it records |
|---|---|
| Identity | the logical key (unique per tenant), the kind of caller (tool call, process task, integration, external worker, direct), the mode (live, shadow, eval) |
| Target | the action, a digest of its input schema plus its effects declaration, and a snapshot of that declaration |
| Payload | the arguments, sealed under the subject's erasure scope; `args_digest`, an HMAC-SHA256 under the same scope's key; the preconditions (subject ids and their `version_number`) |
| Who | the requesting person, the executing principal (a person or a named automation principal), and the delegation chain in RFC 8693's nested `act` shape |
| Lineage | run, step and tool-call ids, process instance and node, parent invocation, rerun-of, release manifest, correlation id, `traceparent` |
| Approval | the mode (`none`, `confirm`, `four_eyes`), the `HumanTask`, `approval_digest` (RFC 8785 canonical JSON, SHA-256, of the granted `authorization_details` in RFC 9396's shape), approver, expiry |
| Lease | `lease_epoch`, `lease_expires_at`, attempt count, next attempt, deadline |
| Outcome | status, failure class, error code, the sealed result, and the confirmed external effect (system, reference, when observed, how reconciled) |

The lifecycle is `requested → awaiting_approval → ready → executing → (dispatched) → succeeded | failed |
outcome_unknown`, plus `rejected`, `stale` and `cancelled`. `outcome_unknown` leaves only through reconciliation.
Terminal states never change. Attempts are the row's AshEvents history, not a second table.

### One door

A caller uses one code interface, `Execution.invoke(target, args, %{key: k, parent: p}, actor: actor)`. It reads by
key first: the same key with the same target, `args_digest`, principal and parent returns the existing row; the same key
with anything different is an `:idempotency_conflict`. It does not upsert, because an upsert on a logical key can hand
one caller another caller's result. Concurrent callers that miss the read collide on the identity, and the loser
re-reads and applies the same comparison.

An action that is governed carries `AshAgent.Validations.Governed`. It refuses to run unless its context names an
Invocation that it loads and finds `executing` at the given epoch, for this target, with an `args_digest` equal to the
digest of the actual inputs and an actor equal to the rebuilt executing principal. A context the caller made up is not
enough.

### Three execution paths

| Effect | Path | Guarantee |
|---|---|---|
| Writes to this repository only (`open_world?: false`) | the claim commits; one transaction runs the target and the fenced `succeed` | exactly one committed effect, provided the target makes no outbound call in a transaction hook, which a contract test checks with outbound HTTP blocked |
| External, idempotent with a provider key | the claim commits; the call carries the invocation key as the provider's idempotency key; the fenced `succeed` follows | at least once, deduplicated by the provider |
| External, not idempotent | as above | a lost acknowledgement becomes `outcome_unknown`; the declared reconciliation read resolves it, or a person does. Never a blind retry |

A `claim` takes `optimistic_lock(:lease_epoch)`. Every completion is filtered on the epoch it claimed with, so a worker
whose lease expired gets `StaleRecord` and its transaction, including its pre-written audit event, rolls back. The model
call or external call happens with no transaction open, between the committed claim and the fenced completion.

### Identity at execution

At every claim the host's `ExecutionIdentity` implementation builds a fresh `ActorContext` from current grant rows. A
person runs as themselves. An automation principal ([ADR 0043](0043-automation-authority-is-a-grant.md)) runs on its
own grants with no bypass, and when a person asked for the work, on the intersection of the person's context and the
principal's. A BPMN service task that calls a governed target runs as the instance's starter or as the definition's
declared automation principal under the same rule, never as `process`; legacy allowlist entries that are not governed
keep `process` until each is migrated. The `ai` system actor still resolves to an empty context. The runtime mints no
actors.

### Approval

The approval door is the existing ash_bpmn `HumanTask`; this record adds no approval mechanism and retires three.
`request` opens the task through a host change that computes candidates, the four-eyes exclusion and expiry from the
target's effects declaration at runtime and delegates to `AshBpmn.Changes.RequireApproval`. The task key is a static
`"invocation.approval"` per subject: one invocation has one approval, and ash_bpmn already keeps pending approvals unique
per subject and key. `approval_digest` is written once by `request` and never accepted again.

No `on_complete` callback is used. A trigger applies the decision: it reads the completed task, checks the decider is a
person and not the executing principal, recomputes the digest from the row, its current preconditions and the current
target digest, and compares it with `approval_digest`. A mismatch makes the row `stale`; a match records the approver
and moves it to `ready`. The trigger's scheduler sweep heals a crash between the decision and its application.

Every claim rechecks expiry, the digests, the preconditions and the approver's authority, from a freshly built context.
An approval is provenance, not an exemption: a revoked grant on the executing identity fails the claim as `:denied`, and
a revoked approver role makes the row `stale`. Who may approve depends on the mode: in `confirm` the person who
delegated may confirm their own agent's proposal and an automation principal never may; in `four_eyes` the requester
is excluded.

### Typed failure

| Outcome | Failure class | Next |
|---|---|---|
| `Ash.Error.Forbidden` at claim or execution | `:denied` | terminal |
| `Ash.Error.Invalid` | `:rejected` | terminal |
| `AshAgent.BusinessError{code}` | `:business` | terminal; becomes a BPMN error a boundary can catch |
| transient integration error | `:transient` | back to `ready` with backoff, within the declared policy |
| permanent or configuration error | `:permanent` | terminal |
| deadline | `:timeout` | terminal, or `outcome_unknown` for non-idempotent external work |
| budget refused | `:budget` | the agent run waits on budget |

### Callers

| Caller | Key |
|---|---|
| Agent tool call | `run:<run_id>:<step_seq>:<tool_call_id>` (the step is included because a self-hosted model server may repeat call ids across turns) |
| BPMN service task | `bpmn:<instance>:<token>:<node>`; a redelivery returns the recorded result. A target that needs approval is refused at publish: model a user task instead |
| Integration action | supplied by the caller, sent on as the provider's idempotency key where the provider supports one |
| A person on the web, ACP or the assistant | per request; governed targets have no door but `invoke` |
| `/mcp` | per call; `assign_role` becomes governed and its result carries the approval link |

## Does it consume ActorContext?

Yes, at two points, and no policy check queries.

1. **At every claim.** The executing identity is a fresh `ActorContext` built from grant rows, through the host's
   implementation of `AshAgent.ExecutionIdentity`. Building it is claim logic in a change, not a policy check, so the
   rule that checks never query is untouched. The pre-check at `request` (`Ash.can?` as the executing identity) is also
   in a change.
2. **To read an invocation.** The inherited grant union applies, plus one `extra_grants` filter check modelled on
   `TaskCandidacy`: `approval_task_id in ^ActorContext.for_actor(actor).task_ids`, false for system and nil-user
   contexts. Operators whose roles already read every task reach invocations through a role grant instead, because
   their precomputed `task_ids` is deliberately empty.

`invoke` and `request` are self-service ([ADR 0052](0052-self-service-actions.md)): `request` relates the actor as
owner and validates that the actor owns the parent run or instance. The lease and decision actions are reachable only
by the `:oban` system actor. Both of those restrictions narrow a bypass; neither adds a `forbid_if`.

## Consequences

- One record answers "what was asked, by whom, approved by whom, against which arguments, and did it happen" for agent,
  process and integration work alike.
- A stale worker cannot complete work another worker has taken over, and an internal effect commits with its
  completion or not at all.
- An approval cannot be reused for different arguments, a changed subject, a changed target or a revoked approver.
- External effects are at least once, never exactly once. A non-idempotent call whose acknowledgement is lost is
  reported as unknown and resolved by a lookup or a person; that is a cost operators see.
- Every governed act pays a row, an audit event per transition and, where it needs approval, a `HumanTask`. Reads that
  are not open-world stay in the agent's loop and pay nothing.
- Approval candidates, the four-eyes rule and expiry come from the effects declaration, so a target without one cannot
  be governed ([ADR 0057](0057-actions-declare-their-effects.md)).
- The trust this design places on readings of source is tested before code depends on it: resuming the ash_ai loop with
  tools that only return recorded results; the epoch filter and optimistic lock rolling back the AshEvents event; the
  internal-effect transaction with outbound HTTP blocked; a standalone approval through the host's `HumanTask` door; an
  RFC 8785 encoder against the RFC's vectors. Each result, including a negative one, is added to this record.

## Reversal

Before any governed target exists, delete the fragment instance and its migration; nothing else depends on it. After
targets are governed, reversal means removing `Governed` from each target and pointing its callers back at the action
directly, which reopens the gaps in Context (untyped failures, unbound approvals, `/mcp` writes without approval). The
rows already written stay as history. Replacing the approval door with something other than `HumanTask` touches only
the host's `AshAgent.Approvals` implementation and the apply-decision trigger.

## Built, 2026-10-29

- **The record.** `AshEnterprise.Execution.Invocation` (table `exec_invocations`) instantiates the package's
  `AshAgent.Invocation` fragment on the platform base: tenant-scoped, user-owned, audited, not temporal, no soft delete,
  and the fragment's state machine in place of the base's lifecycle. `invoke` and `request` are self-service;
  `claim`, `succeed`, `fail`, `apply_decision` and `execute` are machinery-only, so only the `oban` system actor reaches
  them and no grant does.
- **One door, no upsert.** `Execution.invoke/4` reads by key and compares target, `args_digest`, principal and parent;
  a mismatch is `AshAgent.Invocation.IdempotencyConflict`. Concurrent callers that miss the read collide on the key's
  identity and read again. A target names `"<resource module>.<action>"` and must carry an effects declaration
  ([ADR 0057](0057-actions-declare-their-effects.md)); arguments are checked against the action's inputs without
  running it or its changes, and a request whose arguments do not fit is recorded as `rejected`.
- **The parent.** A request may name only a parent invocation the requester owns or a process instance they started;
  a `run_id` is refused until runs exist. Calling `request` directly gains nothing over `invoke`.
- **Sealing.** `args` and `result` are sealed under the subject's erasure scope when the target acts on a record that
  has one, otherwise under the requester's own `data_subject` scope (ref `invocation_requester:<user id>`).
  `args_digest` is an HMAC-SHA256 over RFC 8785 canonical JSON, keyed by an HMAC of a fixed label under that scope's
  data key, so a shred leaves the digest unrecomputable. A requester whose scope was shredded cannot invoke until a
  scope-rotation rule exists.
- **Identity.** A person's request executes as that person: the principal is stored at request, and at every claim
  the person is read again and their `ActorContext` rebuilt from grant rows; an inactive or missing person fails the
  row as `:denied` without running the target, and so does a person who no longer belongs to the row's tenant.
  System actors are not principals. An automation principal runs on the intersection of its own grants and its
  requester's, and only for an agent its requester holds the start grant for. All three are rebuilt at every claim
  ([ADR 0043](0043-automation-authority-is-a-grant.md), "Built"; `reauth_test.exs`). A target whose record the
  executing actor can no longer read is `:denied`, and one whose record is gone is `:rejected`.
- **Lease and paths.** `claim` takes the next epoch under `optimistic_lock(:lease_epoch)`; `succeed` and `fail` are
  filtered on the claimed epoch, after a locked re-read. An internal target runs in one transaction with `succeed`,
  so a superseded worker's effect rolls back with its refused completion (`lease_fencing_test.exs`). An expired lease
  is taken over only for an internal target. An external target runs with no transaction open and `succeed` follows.
  Reconciliation is under "Built, 2026-10-29: execution paths, typed failure and reconciliation".
- **Handoff.** `request` and `apply_decision` enqueue the `:execute` job in their own transaction; the trigger's
  scheduler sweeps every minute, takes the tenant from the row and persists no actor (`handoff_test.exs`).
- **Failure classes.** See "Built, 2026-10-29: execution paths, typed failure and reconciliation".
- **The worked example.** A synthetic clinic (`AshEnterprise.Credentialing`, seeded by `mix ash_enterprise.demo`)
  has one governed target: `Credential.activate_credential`, open-world, idempotent, four-eyes by a credentialing
  committee, reconciled by `lookup_activation`, against a stub registry that keeps no record. Clinic and clinician are
  the CDM `Account` and `Contact`; the credential is invented. `clinic_scenario_test.exs` runs it from `invoke`
  through an applied approval to the registry's reference.
- **Not built yet.** Opening and applying approvals (`awaiting_approval` rows wait for a host change on
  `apply_decision`), the approval trigger, the pre-check of the executing identity at request, and `rerun`.

## Built, 2026-10-29: execution paths, typed failure and reconciliation

- **Paths by effect.** The executor takes the path from the target's declaration, which the claim has matched to the one
  requested. An internal target's expired lease is made ready again (`requeue`): its effect rolled back with its
  transaction. An idempotent outside target is given the invocation key in `context.ash_agent.invocation_key`, and the
  Nango façade sends it as `Idempotency-Key` when a target passes `idempotency_key`; its expired lease is re-readied
  too, and the provider takes the repeated call once. An outside target that is not idempotent is never called twice
  for one claim: an error that leaves its effect in doubt, or a lease that expires with nothing recorded, makes the row
  `outcome_unknown` (`reconcile_test.exs`).
- **Reconciliation.** The `:reconcile` trigger (a sweep every minute, and enqueued by `mark_outcome_unknown` in its own
  transaction) runs the package's `reconcile` action. An unknown outcome is settled by the target's `reconcile_with`
  lookup, run as the rebuilt principal: found is `succeeded` with the effect's reference, not found is `failed` as
  `:transient`, which only a deliberate `retry` runs again. Without a lookup, or when it cannot tell, a person is asked.
- **Resolution by a person.** `request_resolution` opens a standalone `HumanTask` under the key
  `"invocation.resolution"` for the tenant's administrators, through `AshBpmn.Changes.RequireApproval`. Its outcomes are
  `succeeded`, `failed` and `retry`, which no door offered: the board's Complete is limited to outcomes the checked-in
  baselines declare, and standalone approvals to approve and reject. `HumanTask.resolve` offers exactly those three
  (an enumerated argument, so a picker), accepts only a resolution task, and `approve`, `reject` and `complete_task`
  refuse one. The `:apply_resolution` trigger reads the completed task, requires a person as the decider, and applies
  it: `succeeded`, `failed`, or `retry` (ready again, same key and arguments) (`resolution_test.exs`). Never
  `on_complete`.
- **Dispatch.** A target that hands its work on returns an `AshAgent.Invocation.Dispatch`: the row is `dispatched`,
  holds no lease, and is settled by `complete_external` or by its deadline: `outcome_unknown` with `:timeout` for
  outside work that is not idempotent, a `:timeout` failure otherwise. A callback for a row that is already final is
  appended to `evidence` and changes nothing else.
- **Typed failure.** As the Typed failure table above, from `AshAgent.Invocation.Failure`. `AshEnterprise.Integration.ProxyError`
  classifies itself (`AshAgent.FailureClass`): `:rate_limited` is `:transient`; `:server_error`, `:transport` and
  `:nango_error` are indeterminate (the effect may have happened); the rest `:permanent`. A transient failure backs off
  (30 seconds, quadrupling) for up to three claims, then fails, and `retry` makes it ready again. `:budget` has no
  source in the host until agent runs exist. `AshAgent.Invocation.Failure.bpmn/1` gives what a process sees: a
  business error code, an incident, or waiting (`typed_failure_test.exs`).
- **The no-network contract.** `no_network_contract_test.exs` is a CI gate over every target declared internal and not
  read-only in the registered domains: built with generated inputs as an administrator, it may attach no transaction
  hook, and run inside a rolled-back transaction with every outbound `Req` request blocked, it may make no request. A
  canary target whose `after_transaction` hook calls the Nango façade fails it. Generated inputs do not reach every
  action's end (a target needing an existing record stops at its lookup), so for those the hook check is what holds.

## Amendment, 2026-10-29 — the coding-agent bridge

Decided by Luke on 2026-10-22 and recorded here a week later. The coding-agent bridge in `AshEnterprise.Agents` has two
halves, and they go different ways.

- **The approval half moves onto the invocation.** `Agents.ToolGate` and the `Agents.ToolInvocation` rows it approves
  are one of the five mechanisms listed under Context. When agent tool calls become governed (phase 2b of the build), a
  bridge tool request becomes an `Execution.invoke` with a tool-call key as in the Callers table, its approval is the
  invocation's `HumanTask` and `approval_digest`, and `ToolGate` becomes a caller of that one door. `ToolInvocation`
  stops being written; the rows it already holds stay as history.
- **The session half stays separate.** `Agents.AgentSession` and `Agents.AgentRun` record an external coding agent's
  process and conversation. They are not the runtime's `Run` and `Step`
  ([ADR 0056](0056-the-ash-agent-package.md)), which record runs this application's own agents execute, and they are
  not merged into them.
