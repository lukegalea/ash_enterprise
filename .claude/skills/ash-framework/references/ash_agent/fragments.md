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
