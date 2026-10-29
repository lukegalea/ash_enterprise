defmodule AshEnterprise.Security.Checks.SystemActorReach do
  @moduledoc """
  What the system-actor bypass authorizes (ADR 0059): any action, except that
  a `human_only` action admits no system actor and a `machinery_only` action
  admits only `AshEnterprise.Platform.SystemActor.oban/0`.

  It sits inside the bypass, after `AshEnterprise.Security.Checks.SystemActor`
  has established that the actor is a system actor, so the closed list of
  system actors is unchanged; only how far one reaches is narrowed. On a
  narrowed action the bypass authorizes nothing and the grant union decides,
  where `AshEnterprise.Security.Checks.RoleGrant` asks the same question of a
  system actor rather than admitting it outright.

  A simple check that reads compile-time DSL and the actor struct only
  (`AshEnterprise.Security.ActionReach`).
  """

  use Ash.Policy.SimpleCheck

  alias AshEnterprise.Security.ActionReach

  @impl true
  def describe(_opts),
    do: "action is not human_only, and is machinery_only only for the oban system actor"

  @impl true
  def match?(actor, %{resource: resource, action: action}, _opts),
    do: ActionReach.system_actor?(actor, resource, action)

  def match?(_actor, _context, _opts), do: false
end
