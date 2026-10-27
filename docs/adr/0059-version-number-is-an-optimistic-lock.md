# ADR 0059 — `version_number` is an optimistic lock; human-only and machinery-only actions narrow the bypasses

- **Status:** accepted (2026-10-23), implemented
- **Date:** 2026-10-23

## Context

Two platform properties were weaker than the documents describing them, and both matter as soon as an approval or a
background job acts on a row someone else may also be editing.

**`version_number` counted nothing.** `AddSystemAttributes` adds it to every platform resource with `default: 1` and
the description "incremented on write. Used for optimistic locking". Nothing incremented it. The only code that set it
was the strangled read model `Legacy.User`, which projects it as the constant `1`. So every row read `1` forever, a
stale write silently overwrote the write it had not seen, and a precondition of the form "this row has not changed
since version N" would always pass.

Ash ships the change this needs, `optimistic_lock/1`. It adds `version_number = N` (N read from the record being
updated) to the update's filter and increments the column. A plain `increment` is not enough. On a non-atomic update,
it computes N+1 from the row each writer loaded, so two writers both write N+1 and the second wins. Every audited
update here is non-atomic, because the AshEvents wrapper refuses atomic changes on audited resources. The wrapper does
still pass the changeset's filter to the data layer's `UPDATE … WHERE`, which is what the lock relies on.

**Three bypasses cover every action.** The policy set every platform resource inherits (`Security.Policies`) opens
with three bypasses ahead of the grant union: the process engine's (`AshBpmnInteraction`), the decision engine's
(`AshDecisionsInteraction`) and the system actor's (`SystemActor`, every system actor but `ai`). A bypass covers every
policy declared after it. So no action could be reserved for a person: a background job, or any call an engine marked
as its own, reached it whatever the policies after the bypasses said. `RoleGrant` also admitted any system context
outright. And no action could be reserved for the background job runner, because role grants are per verb, not per
action: a person with `write` on a resource reached every update on it.

The one place that needed a person-only action so far (`Erasure.Scope.shred`) worked around this by declaring its own
complete policy set with `policies?: false`.

Luke decided both questions on 2026-10-22: use Ash's own `optimistic_lock` on update actions platform-wide, exempting
strangled resources that project the column as a constant; and reuse the `oban` system actor for machinery rather than
add a new one, narrowing the bypasses for human-only actions and narrowing the system-actor bypass to `oban` for
machinery actions.

## Decision

### `version_number` is an optimistic lock

`AshEnterprise.Platform.Resource` adds

```elixir
changes do
  change optimistic_lock(:version_number), on: [:update]
end
```

to every resource, controlled by a new option `optimistic_lock?` (default `true`). Every update action, including the
generated lifecycle transitions, now:

- writes only if the row's `version_number` is still the one the caller read, and fails with
  `Ash.Error.Changes.StaleRecord` otherwise;
- increments `version_number`, so a row created and then written twice reads `3`.

Destroys are not locked. Soft delete is a destroy action, and archiving a row someone else has just edited is not a
lost update.

A resource opts out with `optimistic_lock?: false`, and only where the column is not one this application stores and
writes. Today that is `Legacy.User`, which projects `version_number` as a strangler `constant`. The verifier
`Platform.Verifiers.OptimisticLock` refuses a resource that projects `version_number` as a constant with the lock on, so
the exemption is a declaration someone made and can review, not something found at the first write.

### `human_only:` and `machinery_only:` narrow the bypasses

Two new base-resource options name actions:

```elixir
use AshEnterprise.Platform.Resource,
  domain: AshEnterprise.Clinic,
  human_only: [:approve_referral],
  machinery_only: [:claim, :expire]
```

| Declared | Engine bypasses | System-actor bypass | Grant union |
|---|---|---|---|
| neither | reach it | every system actor but `ai` | applies |
| `human_only` | do not reach it | does not reach it | applies; a system actor gets nothing from it |
| `machinery_only` | do not reach it | the `oban` system actor only | does not apply |

How it is built:

- Each bypass now authorizes through a reach check instead of `always()`. The engine bypasses use `EngineReach`, and
  the system-actor bypass uses `SystemActorReach`. On a narrowed action the bypass authorizes nothing and the call
  falls through to the union. There it is judged by its actor's own grants, like any other call.
- `RoleGrant` asks a system context the same reach question instead of admitting it outright, so the union does not
  hand back what the narrowed bypass withheld.
- The union's condition is `GrantReach` instead of `always()`. It matches every action except a machinery-only one. A
  machinery-only action therefore has exactly one policy that can authorize it: the system-actor bypass, for `oban`.
- The list of system actors is unchanged and stays closed. `oban` is the background job runner and already the actor
  of every trigger.

A bare system `ActorContext` carries no name, so it is not `oban` and does not reach a machinery-only action.

The verifier `Platform.Verifiers.NarrowedActions` refuses three things: a listed action that does not exist, an action
that is both human-only and machinery-only, and an action that is both machinery-only and self-service.

### Why this is still "authorization is data"

Neither option adds a `forbid_if` or any other deny. Each narrows how far an existing path reaches:

- A person's grants on a human-only action are exactly what they were.
- An action that declares neither is authorized exactly as before.
- For machinery-only actions, the union does not *apply*; it does not subtract. A human-only action is a statement
  that "the engine or a job did it" is not an answer. A machinery-only action is a statement that "a role says I may"
  is not one either. Both are facts about the action's code, made in the resource and reviewed in the diff that adds
  them, like `self_service:` (ADR 0052).

## Does it consume ActorContext?

Yes, and it queries nothing. The declarations are compile-time DSL. The reach checks read them and the actor struct
the call was made with: a `SystemActor`'s name, or the `system?` flag of an `ActorContext`. `ActorContext` itself is
unchanged.

## Consequences

- A write made from a stale copy of a row now fails instead of overwriting. Code that updates a struct it has already
  updated once has to use the struct the first update returned, or reload it. Code that relied on last-writer-wins
  now sees the conflict.
- `version_number` means what its description says. Approval preconditions can name a version and be refused when the
  row has moved on.
- A bulk update over a query cannot use the lock atomically (there is no per-row version to compare), so it streams
  record by record. The one bulk update in the application already allows `strategy: [:atomic, :stream]`.
- An approval or decision can be declared human-only and is then reachable only by a person's own grants. A trigger's
  lease or decision step can be declared machinery-only and is then reachable only by `oban`.
- A human-only action called by the process engine on a person's behalf still works if that person holds the grant,
  because the person is the actor. One called by the engine as the `process` system actor no longer works. That is the
  point.

## Reversal

- **The lock:** set `optimistic_lock?: false` on a resource to remove it there. To remove it platform-wide, change the
  option's default in `Platform.Resource`. No migration is involved; the column already exists.
- **The narrowing:** remove an action from `human_only:` or `machinery_only:`. To remove the mechanism, restore
  `authorize_if always()` in the three bypasses and `policy always()` on the union in `Security.Policies`, restore
  `RoleGrant`'s system clause to `true`, and delete `ActionReach`, the three reach checks, both options and
  `NarrowedActions`. The conformance suite's "human-only and machinery-only actions" block would then be deleted with
  it.
