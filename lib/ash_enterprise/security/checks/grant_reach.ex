defmodule AshEnterprise.Security.Checks.GrantReach do
  @moduledoc """
  The condition of the grant union: every action except one the resource
  declares `machinery_only` (ADR 0059).

  A machinery action (a lease, a decision applied by a trigger) is run by the
  background job runner and by nothing else. Role grants are per verb, not per
  action, so a person holding `write` on a resource would otherwise reach every
  update on it, machinery included. Making the union not apply to those actions
  is how the platform says "no grant reaches this" without a `forbid_if`: the
  only policy that can authorize one is the system-actor bypass, narrowed to
  `oban` by `AshEnterprise.Security.Checks.SystemActorReach`. Every other
  action's union is untouched.

  A simple check over compile-time DSL (`AshEnterprise.Security.ActionReach`).
  """

  use Ash.Policy.SimpleCheck

  alias AshEnterprise.Security.ActionReach

  @impl true
  def describe(_opts), do: "action is not machinery_only"

  @impl true
  def match?(_actor, %{resource: resource, action: action}, _opts),
    do: ActionReach.grants?(resource, action)

  def match?(_actor, _context, _opts), do: true
end
