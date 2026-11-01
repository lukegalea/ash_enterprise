# ADR 0055 — Every consequential act is one governed invocation

- **Status:** accepted (2026-10-23); the invocation record, `invoke`, the lease and the `:execute` handoff built
  (2026-10-29); reconciliation, typed business errors and the automation principal built (2026-10-29); approval
  binding built (2026-10-30); BPMN service tasks through `invoke` built (2026-11-01)
- **Date:** 2026-10-23
- **Amended:** 2026-10-29 — the coding-agent bridge; see
  [Amendment](#amendment-2026-10-29--the-coding-agent-bridge). 2026-11-01 — the sole-administrator rule; see
  [Amendment](#amendment-2026-11-01--the-sole-administrator-rule)
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
digest of the actual inputs and an actor equal to the rebuilt executing principal, and unless the context carries the
secret the executor was given at its claim, whose digest only the claim stores. A context the caller made up is not
enough, even one written by the requester, who knows everything about the row but that secret.

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
  has one; an agent run's tool call with no such record takes its run's scope (amended 2026-11-01, see ADR 0056,
  "Erasure of a run"); otherwise they are sealed under the requester's own `data_subject` scope (ref
  `invocation_requester:<user id>`).
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
  has one governed target: `Credential.activate_credential`, open-world, four-eyes by a credentialing committee,
  reconciled by `lookup_activation`, against a stub registry. Clinic and clinician are the CDM `Account` and
  `Contact`; the credential is invented. `clinic_scenario_test.exs` runs it from `invoke` through an applied approval
  to the registry's reference. (Amended 2026-10-31, showcase slice 1: the target is not idempotent, because the
  registry takes no idempotency key and each activation it accepts is an entry of its own; so a lost answer is
  `outcome_unknown`, settled by `lookup_activation`, never a second activation. The stub remembers what it accepted
  for as long as the node runs, so the lookup can answer, and `lookup_activation` takes the target's own `id`. The
  tour at `/app/showcase/credentialing` walks F2, F4 and F5 over it.)
- **Not built yet.** Opening and applying approvals (`awaiting_approval` rows wait for a host change on
  `apply_decision`), the approval trigger, the pre-check of the executing identity at request, and `rerun`. (Approvals
  and their trigger were built on 2026-10-30; see below.)

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

## Built, 2026-10-30: approval binding

- **What an approval binds** is the package's (ash_agent `AshAgent.Invocation.Approval`). `request` writes, for a row
  awaiting approval, `authorization_details` in RFC 9396's shape (a URN `type` naming the action, `actions`, the
  subject as `identifier`, and `target_digest`, `args_digest`, `preconditions`, `manifest_digest` reserved as nil until
  release manifests exist), `approval_digest` (SHA-256 of their RFC 8785 canonical JSON) and `approval_expires_at`
  from the declaration's `approval_expires_in`. `apply_decision` makes an approved row ready only while the digest
  recomputed from the row, the target as declared now and the subject's current `version_number` still matches and
  the approval has not expired; `claim` checks the same, inside its transaction, before every attempt. Otherwise the
  row is `stale` with `error_code` `subject_changed`, `target_changed`, `approval_expired` or `approval_changed`.
- **The task.** `Execution.Changes.RequestApproval` opens the standalone `HumanTask` under `"invocation.approval"`
  through `AshBpmn.Changes.RequireApproval` in the request's transaction. Candidates are the holders of the
  declaration's `approver_role`, named in words (`:credentialing_committee` is the role "Credentialing committee"); a
  `:confirm` target with no role is confirmed by the requester; `:four_eyes` excludes the requester even when they hold
  the role. Automation principals hold no person's role, so they are never candidates.
- **The decision.** `HumanTask.approve`, `reject` and `resolve` are now `human_only` ([ADR 0059](0059-version-number-is-an-optimistic-lock.md)):
  no system actor and no engine-flagged context reaches them. The `:apply_decision` trigger (a sweep every minute,
  `use_tenant_from_record?`, `actor_persister :none`, ash_oban's default lock) selects rows whose task is completed or
  cancelled, or whose approval expired undecided. `Execution.Changes.ReadApproval` takes the outcome from the task,
  never from the caller: approved by a person who may still approve and, under four eyes, is not the requester is
  `:approved`; a rejection is `rejected`; an expired or cancelled task, or an expiry with no decision, is `stale`; an
  approval by someone without authority is `stale` with `approver_unauthorized`. The task is recorded as
  `approval_task_id`.
- **Authority at every claim.** `Execution.Changes.RecheckApprover` re-resolves the approval's candidates and builds
  the approver's `ActorContext` afresh: an approver who lost the role, left the tenant or was deactivated makes the row
  `stale` (`approver_unauthorized`) and nothing runs.
- **Reading.** `Security.Checks.InvocationApprovalCandidacy` lets a candidate read the invocation they are asked to
  approve. It filters on `exists(approval_task, id in ^task_ids)` rather than on the `approval_task_id` column, because
  the engine creates the task after the row is inserted and writing the id back would cost a second audited write;
  `approval_task_id` is recorded when the decision is applied.
- **Tests.** `approval_binding_test.exs` (durability tier) and, for the ash_agent ↔ ash_bpmn seam on the battery's own
  instantiation, `battery/test/base_integration/invocation_approval_test.exs`.

## Built, 2026-10-31: what an attempt may have done

A review of Phase 1 found five ways a row could record an outcome the world does not bear out. Each was reproduced
first, and each is now the package's (ash_agent `AshAgent.Invocation`), with the host's tests in
`attempt_outcomes_test.exs` (durability tier) and `governed_test.exs`.

- **The executor alone runs a governed target.** Everything Governed checked is known to the requester, the lease
  epoch being a small counter, so while a row was executing the requester could call `assign_governed` beside the
  executor. Each claim now makes a secret, stores only its digest (`lease_token_digest`), and hands it to the target
  in `context.ash_agent.lease_token`; a caller without it is refused as `:not_executor`.
- **The subject is checked where it is written.** The claim checked the approved `version_number`, and the target
  read the subject again in a later transaction, so an edit between them ran under the old approval. The executor now
  compares the record the target is about to write with the approved version (inside the target's transaction for an
  internal one); another version makes the row `stale` through `mark_stale`, with nothing run. The base resource's
  `optimistic_lock(:version_number)` then fences the write itself to that version.
- **An outside target that started is in doubt when it fails.** An error the host has not classified, from an outside
  target past its start, was final (`:rejected` or `:permanent`) though the call may have gone out; `activate_credential`
  losing its own write's version race after the registry call is the case. It is now indeterminate: an idempotent target
  runs again with the same key, then becomes `outcome_unknown` if it runs out of attempts; one that is not idempotent is
  `outcome_unknown` at once. A policy refusal stays `:denied`, and what is refused before the action starts (inputs that
  do not build, a subject gone or out of reach) stays definite.
- **A raise is an outcome, and attempts are counted.** An outside target that raised left the row `executing`, and
  every lease expiry re-ran it. A raise is now recorded as indeterminate, and an expired lease is taken over or
  re-readied only while `attempt_count` is below `max_attempts`; past that, `reconcile` makes it `outcome_unknown`
  (outside) or a `:transient` failure, `"attempts_exhausted"` (internal).
- **A row an attempt may have reached outside never ends as though nothing ran.** Going `stale` at claim (a changed
  target, an expired approval, a changed subject, an approver who may no longer approve), being cancelled from
  `ready`, or failing before its target ran makes such a row `outcome_unknown` instead, with the same `error_code`, and
  reconciliation settles it. `RecheckApprover` refuses an attempt through the package's `Claim.stale/2` for the same
  reason.

## Built, 2026-10-30: governed targets and `/mcp` `assign_role`

- **The validation** is the package's (ash_agent `AshAgent.Validations.Governed`, taking the host resource as
  `invocation: AshEnterprise.Execution.Invocation`). It reads the invocation named in `context.ash_agent` without
  authorization, in the action's tenant, and refuses unless it is `executing` under the named epoch, for this target,
  with an `args_digest` equal to the HMAC of the inputs given plus the acted-on record's primary key (taken from the
  record), and run as its principal. A refusal is `AshAgent.Invocation.Ungoverned` (invalid) with a `reason`. It has an
  `atomic/3` and is temporal safe.
- **The principal check** needs the inverse of `actor_for/1`, so `AshAgent.ExecutionIdentity` gained
  `principal_of/1`. `Execution.Identity` reads it from the actor alone: a `User` is the person (one asking to start an
  agent is not an actor `actor_for/1` builds), an `AutomationPrincipal` acting for a person is that automation
  principal; anything else, system actors included, has none.
- **Governed targets in Phase 1**: `Security.UserRole.assign_governed` and the clinic's
  `Credentialing.Credential.activate_credential`. `UserRole.assign` stays ungoverned for the callers that have not
  moved to `invoke` (the tenant seeder, demo data, the access-request process, the assistant's confirmed proposals, the
  admin UI and test fixtures): moving them is the caller inventory this ADR puts before wider use.
- **`/mcp` `assign_role`** is now `UserRole.request_assignment`, a self-service generic action
  (`Execution.Actions.RequestInvocation`) that calls `invoke` for `assign_governed` with a per-call key
  (`request:<UUIDv7>`) and returns the request: `invocation_id`, `target`, `status`, `error_code` and, while it waits,
  `approval_url` (`/app/r/approvals/<task id>`), which the MCP router sends as `structuredContent`. Nothing is assigned
  until an administrator other than the caller approves; the assignment then runs as the caller, rebuilt from their
  grants.
- **Tests.** `test/ash_enterprise_web/mcp_assign_role_test.exs` drives the tool through the MCP router with a bearer
  token: the call returns the approval URL and assigns nothing; approved by a second administrator it runs once.
  `test/ash_enterprise/execution/governed_test.exs`: a direct call, a forged context (awaiting approval, ready, another
  epoch, another tenant), other arguments and another actor are each refused; the credential activation refuses a
  direct call. `clinic_scenario_test.exs` runs the governed activation end to end.

## Built, 2026-10-31: band-table certification and revocation

- **Governed targets** now include `SystemOne.CalibrationRun.certify_and_publish` and
  `SystemOne.BandTableCertification.revoke`: `approval: :confirm` by an administrator, `Governed`, an agent's request
  keyed `certify:<run id>` / `revoke:<certification id>`. `record_verdict` is not governed and has no request action
  (AST-136).
- **A person's own click** goes through `invoke` as well: `Execution.Actions.ConfirmInvocation` invokes, approves the
  task as the requester (allowed in `confirm` when they hold the approver role), and runs `apply_decision` and
  `execute` inline. Details are in the amendment to [ADR 0061](0061-judgment-surfaces-ship-with-the-package.md).
- **Tests.** `test/ash_enterprise_web/judgment_surfaces_test.exs`.

## Built, 2026-11-01: BPMN service tasks through invoke

- **The key.** A registry entry of `AshEnterprise.Process.ActionInvoker` that names a declared target
  (`invoke: {resource, action}`) runs through `AshEnterprise.Process.ServiceInvocation`: `Execution.invoke` with the
  engine's invocation key written out, `bpmn:<instance>:<token>:<node>`, the same for every redelivery of one
  execution of the node (ash_bpmn B5), and the instance and node as its parent. A redelivery gets the row back and
  answers with what it recorded; the target runs once. Executed inline, in the advance job.
- **Who it runs as.** The instance's starter (`started_by_id`), rebuilt from grant rows when the task asks and again
  at the claim; a starter who is no longer active stops the task before anything is asked. The definition's
  automation principal is not built: no definition declares one, and where a process would declare it, and which
  agent's start grant it would need, are still open. Entries that name no target keep `process`.
- **What may be named.** Only a target with `approval: :none` and `open_world?: false`. `ServiceInvocation.runnable/1`
  refuses the others, and a diagram naming such an entry is refused at publish.
- **Typed failure.** A `failed` row of class `:business` is `{:bpmn_error, code, %{"invocation_id" => id}}`, which an
  error boundary on that `errorCode` catches; any other final failure is an error the engine retries (and the row
  answers the same each time). The first targets are the clinic's evidence checks,
  `Credentialing.Credential.check_documents` and `check_expiry`.
- **Decisions are recorded or fail.** The process's business rule tasks, System One banding and MDM banding evaluate
  with `record: :required`: a decision whose `Evaluation` row could not be written is an error, not an unrecorded
  answer. The `judge_*` calls that run inside an invocation already carry its id through `SystemOne.judge_context`.
- **Tests.** `test/ash_enterprise/process/invocation_key_test.exs`, `evidence_check_boundary_test.exs`,
  `decision_resolver_test.exs`; battery scenario `process_service_task_invocation_test.exs`.

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

## Amendment, 2026-11-01 — the sole-administrator rule

Publishing an agent (`AgentVersion.apply_publish`) is `:four_eyes` with `approver_role: :administrator`. An
organization with one administrator could never publish one: four eyes excludes the requester and there is no second
candidate. Adding a second administrator only to approve, or leaving agents unpublished, were the alternatives; the
decision is an explicit, recorded exception instead.

- **Opt-in, per organization.** `Organization.sole_administrator_approval`, default false, set only through
  `set_sole_administrator_approval`: `human_only` and `changes_authority` (a person's act, never a system actor's, an
  engine's or an automation principal's), authorized by the grant union and by `Security.Checks.OwnOrganization`
  (the row is the actor's own organization, since `Organization` is not tenant-scoped). Audited like every update.
- **The rule.** For a `:four_eyes` declaration whose `approver_role` is `:administrator`, and no other role, the
  requester is not excluded while the organization has opted in and the requester is the only active member holding
  the Administrator role, directly or through a team (`Execution.Approval.sole_administrator?/3`). Turning the opt-in
  on in an organization with several administrators changes nothing. The credentialing committee, and every other
  approver role, keeps four eyes unconditionally.
- **Still an act, asked again.** The requester approves by deciding the task, as any approver does; nothing is
  approved for them. The rule is evaluated when the task opens (`RequestApproval`, which now passes the tenant and the
  requester to `Approval.task_options/4`), when the decision is applied (`ReadApproval`) and at every claim
  (`RecheckApprover`, through `approver_holds?/2`). A second administrator, or the opt-in turned off, restores four
  eyes: a self-approval not yet applied goes `stale` with `approved_by_requester`, one already applied goes `stale` at
  its claim with `approver_unauthorized`, and nothing runs.
- **Recorded.** `Invocation.approval_basis` is written when an approval is applied: `:confirm`, `:four_eyes` or
  `:sole_administrator`, so a reader of the row or its audit trail can tell a self-approval from four eyes.
- **Enabling an agent.** `AgentVersion.enable_from_code` (and `mix ash_enterprise.assistant.enable --org <org> --as
  <email>` for the assistant) registers the code agent's platform baseline, forks it into the tenant and requests the
  publish as the named person; a rerun returns the waiting request or reports the version already published. It never
  approves and never gives start grants. `--sole-administrator-approval` records the opt-in first, as that person.
- **Tests.** `test/ash_enterprise/execution/sole_administrator_approval_test.exs` and
  `test/ash_enterprise/execution/enable_agent_test.exs`.
