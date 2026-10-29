defmodule AshEnterprise.Security.Checks.EngineReach do
  @moduledoc """
  What the process and decision engine bypasses authorize: any action except
  one the resource declares `human_only` or `machinery_only` (ADR 0059).

  It sits inside those bypasses, after the engine's own check has matched, so
  a call the engine marked as its own still skips the grant union everywhere
  else. On a narrowed action the bypass authorizes nothing and the call falls
  through to the union, where it is judged by its actor's own grants, as any
  other call would be. Nothing is denied that a grant allows.

  A simple check: the answer depends on the action, not the record. It reads
  compile-time DSL only (`AshEnterprise.Security.ActionReach`).
  """

  use Ash.Policy.SimpleCheck

  alias AshEnterprise.Security.ActionReach

  @impl true
  def describe(_opts), do: "action is neither human_only nor machinery_only"

  @impl true
  def match?(_actor, %{resource: resource, action: action}, _opts),
    do: ActionReach.engine?(resource, action)

  def match?(_actor, _context, _opts), do: false
end
