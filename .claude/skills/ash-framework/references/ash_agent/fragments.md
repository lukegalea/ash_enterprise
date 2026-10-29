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
6. A row in `succeeded`, `failed`, `rejected`, `stale` or `cancelled` never changes. Do not add update actions that
   bypass the state machine.
7. Every claim compares the row's `target_digest` with the target as declared now. A row whose target changed since it
   was requested (its inputs or its effects declaration) becomes `stale` with `error_code: "target_changed"` and does
   not run, so a deploy that changes a target leaves its queued and approved rows stale. Request them again.
8. If your audit wrapper refuses atomic updates, nothing changes: fencing is a filter on the update plus
   `optimistic_lock`, never an atomic update.
9. Set `lifecycle?: false` (or the equivalent) if your base resource installs a state machine of its own: the
   fragment's state machine is the row's lifecycle, and two do not merge.

### What you add on the resource

| You add | Why |
|---|---|
| Tenancy and an owner column | The fragment has neither; stamp the owner on `request` from the actor |
| Policies | `invoke` and `request` for the people who may ask; `claim`, `succeed`, `fail`, `apply_decision` and `execute` for your job runner alone |
| Encryption of `args` and `result` | Both are marked `sensitive?`; seal them if you encrypt content at rest |
| A check of `parent` | The fragment records the parent; whether the requester may name it is yours to decide |
| The `:execute` trigger | `request` and `apply_decision` enqueue it for every ready row |
| Approval opening and deciding | Attach a change to `request` (rows that land in `awaiting_approval`) and to `apply_decision` (set its `outcome`) |
| Any check at claim | Attach a change to `claim`, for example re-checking an approval before work starts |

A change you attach with `changes do change MyChange, where: [action_is(:claim)] end` runs after the fragment's own
changes for that action and before its hooks.
