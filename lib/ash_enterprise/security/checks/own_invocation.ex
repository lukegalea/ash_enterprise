defmodule AshEnterprise.Security.Checks.OwnInvocation do
  @moduledoc """
  A grant path for what others did about a person's request: **a request you asked for
  lets you read every act on it**, whoever did it.

  On `AshEnterprise.Execution.Intervention`: reads of the interventions on an invocation
  the actor owns (`invocation.owner_id`). An intervention is owned by whoever acted, so
  without this a requester following their own requests at `:basic` would read none of
  an operator's acts on them, and the recovery page and the trace would say nobody had
  acted when someone had.

  Reads only: no create, update, destroy or generic action. Someone who also holds a
  role grant keeps everything that grant reaches.

  ## Never queries

  The grant is a filter on the intervention's invocation, with the actor's id from the
  precomputed `AshEnterprise.Security.ActorContext`.
  """

  use Ash.Policy.FilterCheck

  alias AshEnterprise.Security.ActorContext

  require Ash.Expr
  import Ash.Expr, only: [expr: 1]

  @impl true
  def describe(_opts), do: "the record is about an invocation the actor asked for"

  @impl true
  def filter(actor, authorizer, _opts) do
    context = ActorContext.for_actor(actor)

    cond do
      context.system? -> false
      is_nil(context.user_id) -> false
      authorizer.action.type == :read -> expr(invocation.owner_id == ^context.user_id)
      true -> false
    end
  end
end
