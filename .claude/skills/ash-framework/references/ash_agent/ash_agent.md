# Rules for working with AshAgent

## Status

Built: the effects extension, the invocation fragment with its execution paths, typed failure and reconciliation of
outside work whose outcome is unknown, the `Governed` validation that keeps a governed action behind its invocation,
the two behaviours and one protocol it calls, and the agent version fragment with code-declared agents. Not yet built:
the run and step fragments and the approvals and execution-history behaviours.

## Understanding AshAgent

AshAgent records requests for effects (invocations) and durable agent runs for an Ash application. It ships
declarations; the application turns them into resources.

- **The package declares** Spark fragments with attributes, actions, changes, validations, calculations and a state
  machine; an extension for declaring an action's effects; and behaviours for the executing principal, approvals and
  execution history.
- **The host supplies** the base resource and data layer, tenancy, ownership, policies, ash_oban triggers and their
  workers, audit and encryption at rest.

## Rules

1. Include a fragment on a resource built from your own base resource. Do not copy its attributes or actions.
2. Write policies, tenancy and triggers on your own resource. The fragments contain none and will not.
3. Implement the behaviours in your application. The package never reads your actor, tenant or grant data directly.
4. Do not add a reference to Phoenix, or to any application, to this package. CI fails on one
   (`scripts/check-boundary.sh`).
5. This package defines no mix tasks.

## Sub-rules

- [effects](usage-rules/effects.md): declaring what each action does to the world, and checking exposed tools.
- [fragments](usage-rules/fragments.md): the invocation and agent version fragments and how to include them.
- [triggers](usage-rules/triggers.md): the ash_oban triggers a host declares.
- [host-behaviours](usage-rules/host-behaviours.md): the behaviours a host implements.
