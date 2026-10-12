defmodule AshEnterprise.Erasure.Checks.HumanRoleGrant do
  @moduledoc """
  `AshEnterprise.Security.Checks.RoleGrant`, minus the system-actor pass.

  `RoleGrant` treats a system actor as granted, because a system actor is "not
  subject to grants". A shred must be subject to one: it destroys data
  irreversibly, so it is a person's decision with that person's name on it in
  the audit trail — never an Oban job's, a replay's or an agent's. This check is
  therefore false for every system actor (including `ai`, whose context is
  empty), and otherwise exactly `RoleGrant`: the actor must hold a role granting
  `write` on `AshEnterprise.Erasure.Scope`. `Scope` is `ownership: :none`, so
  the only depth that reaches it is `:global`.

  Like `RoleGrant`, it reads only the precomputed
  `AshEnterprise.Security.ActorContext` and never queries.
  """

  use Ash.Policy.FilterCheck

  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Security.Checks.RoleGrant

  @impl true
  def describe(_opts),
    do: "actor is a human (not a system actor) holding a write grant on erasure scopes"

  @impl true
  def filter(actor, authorizer, opts) do
    context = ActorContext.for_actor(actor)

    if context.system? or is_nil(context.user_id) do
      false
    else
      RoleGrant.filter(context, authorizer, opts)
    end
  end
end
