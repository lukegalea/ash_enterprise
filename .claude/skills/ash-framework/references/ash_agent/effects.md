# AshAgent effects declarations

`AshAgent.Effects` is a resource extension that says, per action, what the action does to the world. Anything that has
to decide whether an action is safe to run without asking (a tool loop, an editor's permission prompt, a process
engine) reads the declaration instead of guessing from the action's type or keeping its own list.

```elixir
defmodule MyClinic.Credential do
  use Ash.Resource, domain: MyClinic.Credentialing, extensions: [AshAgent.Effects]

  effects do
    action :read, kind: :read, read_only?: true, open_world?: false, intent: :inspect

    action :activate,
      kind: :edit,
      destructive?: false,
      idempotent?: true,
      approval: :four_eyes,
      approver_role: :credentialing_committee,
      approval_expires_in: [days: 3],
      intent: :execute,
      reconcile_with: :lookup_activation,
      preconditions: [:clinician_id]
  end
end
```

## Vocabulary

- `read_only?`, `destructive?`, `idempotent?`, `open_world?` are MCP's tool-annotation hints. Left out, they take MCP's
  defaults: not read-only, destructive, not idempotent, open-world. Declare what is true; the defaults are the
  cautious reading.
- `kind` is an ACP tool kind (`:read`, `:edit`, `:delete`, `:move`, `:search`, `:execute`, `:think`, `:fetch`,
  `:switch_mode`, `:other`) and is required.
- `approval` is `:none` (the default), `:confirm` (ask before it runs) or `:four_eyes` (a second person from
  `approver_role`, not the one asking). `approval_expires_in` is a duration keyword list.
- `intent` is `:inspect`, `:propose`, `:approve`, `:test` or `:execute`.
- `reconcile_with` names a `:read` or generic action on the same resource that finds out whether an outside effect
  happened.
- `preconditions` name inputs of the action whose records must not change between approval and execution.

## Rules

1. `read_only?: true` only on an Ash `:read` action. A generic action that only looks things up is still not
   read-only: give it `kind: :search` (or `:read`, `:fetch`) and leave the hint alone, or make it a `:read` action.
2. The declaration on your own action is authoritative. Hints read from a foreign MCP server are untrusted input and
   never relax anything.
3. Read declarations with `AshAgent.Effects.Info.effect/2`. It answers `nil` for an undeclared action; treat that as
   MCP's defaults (it writes, and asks first), never as harmless.
4. Add `AshAgent.Effects.Domain` to every domain that exposes ash_ai tools. An exposed action without a declaration
   is a compile error when its resource uses `AshAgent.Effects`, and a compile warning otherwise.
5. Spark reports these verifier errors as compile diagnostics, so build with `mix compile --warnings-as-errors` for
   them to fail the build.
