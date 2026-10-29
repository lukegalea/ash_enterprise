# Rules for working with AshAgent

## Status

The effects extension is built. The rest is not yet: the rules below describe its shape so that an application
adopting it, and an agent working in either repository, knows where each part will live. Each sub-rule says "not yet
built" until its part lands.

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
- [fragments](usage-rules/fragments.md): the fragments and how to include them. Not yet built.
- [triggers](usage-rules/triggers.md): the ash_oban triggers a host declares. Not yet built.
- [host-behaviours](usage-rules/host-behaviours.md): the behaviours a host implements. Not yet built.
