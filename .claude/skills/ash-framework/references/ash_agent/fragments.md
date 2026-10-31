# AshAgent fragments

## `AshAgent.Invocation`

One row for each request to run an action that has effects: a stable key, a keyed digest of the arguments, a lease
that fences stale workers, and a typed outcome. Include it on a resource built from your own base:

```elixir
defmodule MyClinic.Execution.Invocation do
  use Ash.Resource,
    domain: MyClinic.Execution,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOban],
    fragments: [AshAgent.Invocation]

  postgres do
    table "invocations"
    repo MyClinic.Repo
  end

  invocation do
    execution_identity MyClinic.ExecutionIdentity
    digest_key MyClinic.InvocationDigestKey
  end

  oban do
    triggers do
      trigger :execute do
        # see triggers.md
      end
    end
  end
end
```

Expose `invoke` through a code interface on your domain; it is the entry point:

```elixir
resource MyClinic.Execution.Invocation do
  define :invoke, action: :invoke, args: [:target, :args]
end

MyClinic.Execution.invoke(
  "MyClinic.Credentials.Credential.activate",
  %{"id" => credential_id},
  %{key: "review:#{review_id}"},
  actor: nurse
)
```

### Rules

1. A target is `"<resource module>.<action>"`, and only an action with an `effects` declaration can be invoked.
   Declare every action you mean to govern.
2. `args` is the action's inputs as JSON would carry them; for an update or a destroy it also carries the subject's
   primary key. The request checks them against the action without running it or its changes, and records a row that
   does not fit as `rejected`. The subject is read as the caller, with the caller's authorization: a record they cannot
   read is rejected with the same message as one that does not exist, so `invoke` reveals nothing outside what they
   may read. Give the people who ask read access to the records they ask to act on.
3. Use one key per request. The same key with the same target, arguments, principal and parent returns the existing
   row; the same key with anything different is `AshAgent.Invocation.IdempotencyConflict`. Nothing is upserted.
4. Do not call `invoke` inside a transaction you opened: a concurrent request with the same key is detected by the
   key's unique identity, and the failed insert would abort your transaction.
5. `request` derives everything else on the row (principal, kind, mode, lineage, the effects snapshot, digests,
   preconditions, status). Do not add actions that accept those columns.
6. A row in `succeeded`, `failed`, `rejected`, `stale` or `cancelled` keeps its outcome. Two named exceptions: `retry`
   makes a row that failed with `:transient` ready again, and `complete_external` appends a late callback to a final
   row's `evidence`. Do not add update actions that bypass the state machine.
7. Every claim compares the row's `target_digest` with the target as declared now. A row whose target changed since it
   was requested (its inputs or its effects declaration) becomes `stale` with `error_code: "target_changed"` and does
   not run, so a deploy that changes a target leaves its queued and approved rows stale. Request them again. A row an
   earlier attempt of which may have reached outside (an outside target made ready again after a lost lease or a
   failed attempt) is never ended as though nothing ran: where it would go `stale`, be cancelled from `ready`, or fail
   before its target runs, it becomes `outcome_unknown` with the same `error_code`, and reconciliation settles it.
8. A row that waits for an approval records what the approval binds: `authorization_details` (RFC 9396's shape: a
   URN `type` naming the action, `actions`, the subject as `identifier`, and the target digest, arguments digest and
   preconditions), its `approval_digest` (SHA-256 of the RFC 8785 canonical JSON) and `approval_expires_at` from the
   declaration's `approval_expires_in`. `apply_decision` makes an approved row ready only while the digest recomputed
   from the row, the target as declared now and the preconditions' records as they stand now still matches, and the
   approval has not expired; otherwise the row is `stale` with `error_code` `"subject_changed"`, `"target_changed"`,
   `"approval_expired"` or `"approval_changed"`. Every claim checks the same again, and the executor checks the
   subject once more on the record the target is about to write: a subject written after the claim makes the row
   `stale` (`mark_stale`) and nothing runs. Bump `version_number` on every write of a subject with an optimistic lock
   (`optimistic_lock(:version_number)`), or a changed subject goes unseen, and a write that races the target's own is
   not fenced to the approved version.
9. If your audit wrapper refuses atomic updates, nothing changes: fencing is a filter on the update plus
   `optimistic_lock`, never an atomic update.
10. Set `lifecycle?: false` (or the equivalent) if your base resource installs a state machine of its own: the
   fragment's state machine is the row's lifecycle, and two do not merge.

11. Put `validate {AshAgent.Validations.Governed, invocation: MyClinic.Invocation}` on an action whose only door is
    `invoke`. It refuses the action unless the invocation named in `context.ash_agent` is `executing` under the lease
    epoch named there, for this action, with an `args_digest` matching the inputs the action was given (and, for an
    update or a destroy, the primary key of the record it acts on), and run as the principal it executes as
    (`principal_of/1`), by the executor that claimed it: the context must carry `lease_token`, the secret the
    executor was given at its claim, whose digest the claim stored. The requester knows everything else (the row's
    id and key, the epoch, its own arguments), so without it they could run the action themselves beside the
    executor. A context alone is not enough: the validation reads the row. It has an `atomic/3`, so an
    update stays atomic, and it is temporal safe. Anything else is `AshAgent.Invocation.Ungoverned` (invalid), whose
    `reason` names the check that failed. Every other caller of the action (seeds, fixtures, other doors) must then
    go through `invoke`, so put it only on actions whose callers you have moved.

### Execution paths

Which path a claimed row takes depends on the target's effects declaration:

| Target | Path | An expired lease |
|---|---|---|
| `open_world?: false` | The target and the completion in one transaction: exactly one committed effect | Re-readied (`requeue`): the effect rolled back |
| `open_world?: true, idempotent?: true` | The call goes out with no transaction open; the completion follows under the fence | Re-readied, while attempts are left: the call is repeated with the same key. Then `outcome_unknown` |
| `open_world?: true`, not idempotent | As above | `outcome_unknown`, then reconciled. Never called again blindly |
| Returns an `AshAgent.Invocation.Dispatch` | `dispatched`: no lease, until `deadline_at` | — |

12. An idempotent outside target sends `context.ash_agent.invocation_key` as the outside service's idempotency key.
    Declare `idempotent?: true` only when it does: the declaration is what lets an expired lease call it again.
13. Give an outside target that is not idempotent a `reconcile_with` lookup when the outside service can be asked by
    key. Without one, every lost acknowledgement waits for a person.
14. A `reconcile_with` action is a `:read` (a record found means the effect happened) or a generic action returning
    `:succeeded`, `:not_found` or `:unknown`, or a map with that as `outcome` and optionally `effect_ref` and
    `effect_system`. It gets the target's arguments it declares as inputs, and `invocation_key` if it declares one.
    It must not change anything.
15. Return `AshAgent.BusinessError` (with a stable `code`) for a refusal the domain makes, so a process can route on
    it. Implement `AshAgent.FailureClass` for your own error types (see `host-behaviours.md`); an unclassified error
    is `:permanent`, except from an outside target that had started (it built valid and reached its subject): there
    an unclassified error, or a raise, is `:indeterminate`, because the call may already have gone out, and only a
    forbidden error stays `:denied`. Classify the errors your outside targets return before they call out, so they
    are not taken for doubt.
16. A transient failure makes the row ready again after a backoff, up to `max_attempts` claims (the `invocation`
    section, default 3), then fails it as `:transient`; `retry` makes it ready again on purpose. An error that leaves
    an outside effect in doubt (`:indeterminate`) is retried only when the target is internal or idempotent, and an
    idempotent outside one out of attempts is `outcome_unknown`, not failed; a target that is not idempotent is
    `outcome_unknown` at once. An expired lease is taken over, or re-readied, only while attempts are left, so a
    worker that dies every time is not run forever.
17. An `outcome_unknown` row is settled by its `reconcile_with` lookup, by a callback through `complete_external`, or by
    a person: `request_resolution` asks, and `apply_resolution` applies `:succeeded`, `:failed` or `:retry`. Attach a
    change to `request_resolution` that opens your task, and one to `apply_resolution` that sets its `outcome` from the
    decided task.

### What you add on the resource

| You add | Why |
|---|---|
| Tenancy and an owner column | The fragment has neither; stamp the owner on `request` from the actor |
| Policies | `invoke` and `request` for the people who may ask; `retry` and `request_cancel` for the people who may; every other action for your job runner alone |
| Encryption of `args` and `result` | Both are marked `sensitive?`; seal them if you encrypt content at rest |
| A check of `parent` | The fragment records the parent; whether the requester may name it is yours to decide |
| The `:execute` trigger | `request` and `apply_decision` enqueue it for every ready row |
| The `:reconcile` trigger | It settles rows whose lease expired, whose dispatch deadline passed or whose outcome is unknown |
| A resolution task | Attach changes to `request_resolution` (open it) and `apply_resolution` (set its `outcome`) |
| An `AshAgent.FailureClass` implementation | For each error type of yours a target can return |
| Approval opening and deciding | Attach a change to `request` (rows that land in `awaiting_approval`) and to `apply_decision` (set its `outcome` from the decided task). The binding to the request is the fragment's (rule 8); who may approve, and whether the approver may still, is yours |
| Any check at claim | Attach a change to `claim`, for example re-checking that the approver still holds the approver role; to refuse the attempt, call `AshAgent.Invocation.Changes.Claim.stale/2`, which leaves a row an earlier attempt may have reached outside for reconciliation instead |

A change you attach with `changes do change MyChange, where: [action_is(:claim)] end` runs after the fragment's own
changes for that action and before its hooks.

## `AshAgent.AgentVersion`

One immutable, numbered definition of an agent, which a run pins: `key` and `version`, `instructions` (plain text),
`model_profile`, `toolset` (each target with its digest when the version was written), `limits`, `output_type`, and
`content_hash` over them. Lifecycle `draft → published → retired`, one way. Declare an agent in code with
`use AshAgent.Agent` (key, instructions, model profile, tools as `{resource, action}`, limits, output type) and sync it
with `register_from_code`.

```elixir
defmodule MyClinic.Execution.AgentVersion do
  use Ash.Resource,
    domain: MyClinic.Execution,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAgent.Effects],
    fragments: [AshAgent.AgentVersion]

  postgres do
    table "agent_versions"
    repo MyClinic.Repo
  end
end
```

### Rules

1. Sync code-declared agents with `register_from_code`. It returns the key's latest version when the content hash is
   unchanged and writes nothing; otherwise it writes the next version as a draft. Run it on every boot or deploy.
2. Instructions are plain text. The fragment ships no template language. A version is identified by `content_hash`;
   what a model was shown at a step is identified by `AshAi.Transcript.fingerprint/2`, recorded on the step.
3. A toolset target is `"<resource module>.<action>"`, as for an invocation. Its digest is the target's own
   (`AshAgent.Invocation.Target.digest/1`), derived when the version is written; a digest a caller supplies is
   ignored. A target that does not resolve, or declares no effects, is stored with a `nil` digest, and the version
   cannot be published.
4. `apply_publish` refuses a draft with a toolset target that declares no effects, or whose declaration or input
   schema changed since the draft was written, or with a limit missing
   (`AshAgent.AgentVersion.Definition.publish_problems/1`). Revise the draft, then publish.
5. Who runs act as is chosen at publish: `authority` defaults to the requester; an automation principal is named
   explicitly (`%{"type" => "automation", "name" => principal}`). `requesterless: true` is allowed only with an
   automation authority. Check that the principal exists on your resource; the fragment cannot.
6. Publish through an approval. Put `validate {AshAgent.Validations.Governed, invocation: MyClinic.Invocation}` and an
   effects declaration that asks for approval (`approval: :four_eyes, approver_role: ...`) on `apply_publish`, and
   reach it only through `invoke`. The approval binds the draft's `version_number`, so a draft revised while waiting
   goes stale. Check anything else you require of a published version (such as which model profiles may be used) in a
   validation of your own on `apply_publish`.
7. A run pins a version's id and calls `AshAgent.AgentVersion.Definition.check_pinned/1` before every step. A
   drifted toolset target is `AshAgent.AgentVersion.DefinitionDrift` (`reason: :definition_drift`): fail the run
   closed. Publishing a later version or retiring this one does not stop a run already pinned to it.
8. Start new runs on `latest_published` for the key. Never edit a published version; publish another.

### What you add on the resource

| You add | Why |
|---|---|
| Tenancy and ownership | Versions are numbered per key within whatever scope your base gives |
| Policies | Who may sync, draft, request a publish and retire |
| The governed publish path | An effects declaration and `Governed` on `apply_publish`, and an action that asks for it through `invoke` (rule 6) |
| Publish checks of your own | Allowed model profiles, known automation principals |
| Copying a shared baseline | `AshAgent.AgentVersion.Actions.RegisterFromCode.register/3` writes content from anywhere under the same rule as the sync, with `baseline_id` |

## `AshAgent.Run` and `AshAgent.Step`

A durable agent run: one row per run of a pinned agent version (`AshAgent.Run`), and its journal, one row per message
(`AshAgent.Step`). A run is rows and a trigger, not a process. Each `:step` job claims the run, makes one model call
through ash_ai's tool loop with no transaction open, and records what came back under the lease it claimed; a worker
that dies loses only the call it was making.

```elixir
defmodule MyClinic.Execution.Run do
  use Ash.Resource,
    domain: MyClinic.Execution,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOban],
    fragments: [AshAgent.Run]

  postgres do
    table "agent_runs"
    repo MyClinic.Repo
  end

  run do
    agent_version MyClinic.Execution.AgentVersion
    step MyClinic.Execution.Step
    invocation MyClinic.Execution.Invocation
    runtime MyClinic.AgentRuntime
  end

  # oban triggers :step and :recover: see triggers.md
end

defmodule MyClinic.Execution.Step do
  use Ash.Resource,
    domain: MyClinic.Execution,
    data_layer: AshPostgres.DataLayer,
    fragments: [AshAgent.Step]

  postgres do
    table "agent_steps"
    repo MyClinic.Repo
  end
end
```

And on the invocation resource, so a finished tool call wakes its run:

```elixir
changes do
  change {AshAgent.Run.Changes.Wake, run: MyClinic.Execution.Run}, on: [:update]
end
```

### Rules

1. Start a run with `start` (the agent's key and the request as `input`). It pins the key's latest published version
   and refuses a drifted one. Who may start which agent, and who the run executes as, are your
   `c:AshAgent.ExecutionIdentity.run_principal/3`'s answer; a refusal is `AshAgent.Invocation.NoPrincipal`.
2. Never run a tool's effect in the tool loop. Only an Ash `:read` action whose effects declaration has
   `open_world?: false` runs in the loop (as the executing actor, and only when `Ash.can?` says the actor may). Every
   other call stops the loop and becomes an invocation keyed `run:<run id>:<step seq>:<tool call id>`, with the run as
   its parent, requested as `c:AshAgent.ExecutionIdentity.requester_for/1`'s actor. A step repeated after a worker
   died reads the invocation's recorded result; nothing runs twice.
3. One `:step` job is one model call (`max_iterations: 1`). A loop that ran reads and hit the limit is queued for the
   next step; that is not an error.
4. `claim_step` has one winner per epoch, and checks the deadline (`failed`, `:timeout`), drift (`failed`,
   `"definition_drift"`), `max_steps` and `max_tool_calls` (`waiting` on `:limit`) and the token budget (`waiting` on
   `:budget`). Nothing in the package lifts a limit or a budget: a run waiting on one waits for you.
5. `record_step` is fenced on the claimed epoch and the journal's `step_seq`. A refused record changes nothing: no
   step, no invocation, no transition. Give the job runner alone authority over `claim_step`, `record_step`,
   `recover`, `step` and the step resource's `append`.
6. An answer is cast to the version's `output_type`; one that does not cast gets a repair turn (a user message saying
   what was wrong), up to `max_repairs`, then the run fails as `:rejected`, `"output_uncastable"`.
7. `request_cancel` cancels the run and its invocations that have not started, in one transaction; an invocation that
   is executing records the request. Nothing done is undone: reversing an effect is a separate request. A run that
   fails cancels its unstarted invocations the same way.
8. `needs_step` is derived (queued, or waiting on `:tools` with no open invocation). Wake runs with
   `AshAgent.Run.Changes.Wake` on your invocation resource, and keep the `:step` sweep: a lost wake-up costs a sweep's
   delay, never a parked run.
9. The run's `input` and `output` and the step's `parts` are marked `sensitive?`: seal them if you encrypt content at
   rest. The package reads a sealed field through the calculation that opens it.
10. A model call that fails, or a model profile your runtime cannot use now, records nothing: the run stays `running`
    until its lease expires and `recover` queues it again, so the deadline bounds the retries.

### What you add on the resources

| You add | Why |
|---|---|
| Tenancy and ownership | A run is the requester's; copy its owner onto each step so the same grants read both |
| Policies | Who may start (a person, for themselves), read and cancel; the machinery actions for the job runner only |
| The `:step` and `:recover` triggers | triggers.md |
| `Wake` on the invocation resource | A finished tool call enqueues its run's step |
| A check that a tool call's parent run is the requester's | `invoke` records whatever `parent` it is given |
| Sealing | `input`, `output` and `parts` |
| `AshAgent.Runtime` | The model, and the guarded transport that records each call |
