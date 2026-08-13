defmodule AshEnterprise.Security.Checks.SharedWithActor do
  @moduledoc """
  Grant path 2: an explicit `AshEnterprise.Security.AccessGrant`.

  Authorizes when this specific record has been shared with the actor, or with a
  team the actor belongs to, carrying the verb this action needs.

  ## Why this is an `id in [...]` filter rather than an `exists` subquery

  The obvious implementation joins the target resource to `access_grants` on
  every query. `AccessGrant` is polymorphic — `(resource_name, record_id)` with
  no foreign key — so Ash cannot express that as a relationship `exists`, and a
  hand-written subquery would run per row.

  Instead `AshEnterprise.Security.ActorContext` loads **every** grant held by the
  actor's principals in one query at the start of the request, and this check
  turns into a set membership test.

  The tradeoff is honest: the `IN` list grows with the number of records shared
  with one actor. That is acceptable because sharing is meant to be exceptional —
  Dataverse's own documentation calls it "a less performant way of controlling
  access" and advises against using it as the primary mechanism. If a deployment
  finds this list is routinely large, the fix is a role, not a bigger list.

  ## Additive, never subtractive

  Sharing only ever grants. There is no "shared but denied" state, which is what
  keeps the union in `docs/manifesto/03-authorization-is-data.md` order-independent.
  """

  use Ash.Policy.FilterCheck

  alias AshEnterprise.Security.AccessRight
  alias AshEnterprise.Security.ActorContext

  @impl true
  def describe(_opts), do: "record is shared with the actor or one of their teams"

  @impl true
  def filter(actor, authorizer, _opts) do
    context = ActorContext.for_actor(actor)

    if is_nil(context.user_id) and not context.system? do
      false
    else
      verb = AccessRight.for_action_type(authorizer.action.type)

      case ActorContext.shared_record_ids(context, authorizer.resource, verb) do
        # No shares: contribute nothing to the union rather than erroring.
        [] -> false
        ids -> expr(id in ^ids)
      end
    end
  end

  require Ash.Expr
  import Ash.Expr, only: [expr: 1]
end
