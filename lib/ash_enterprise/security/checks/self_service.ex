defmodule AshEnterprise.Security.Checks.SelfService do
  @moduledoc """
  Grant path 4: an action a resource declares **self-service** — something any
  active member of the tenant may do on their own behalf, with no role grant
  (ADR 0052).

      use AshEnterprise.Platform.Resource,
        domain: AshEnterprise.Agents,
        self_service: [:compose_today, :start_for_date, :read]

  | Action type | Authorizes |
  |---|---|
  | generic | the action, outright — it scopes itself to the actor by construction |
  | create / read | rows the actor personally owns: `owner_id` is the actor |

  Nothing else: updates and destroys cannot be declared
  (`AshEnterprise.Platform.Verifiers.SelfServiceActions`), and a resource
  that declares nothing gets nothing from this path.

  ## Why a declaration rather than a grant row

  The role model cannot say "compose your own brief". A generic action maps to
  the `:read` verb (`AccessRight.for_action_type/1`), and a generic action has
  no row for a depth to reach, so `RoleGrant` authorizes one only at `:global`
  — which on the same resource also reaches every other member's rows. Giving
  every member a `:global` grant to let them act for themselves would widen
  exactly what must stay narrow. Self-service is the opposite shape: a fact
  about the *action* (it is the actor's own by construction), reviewed in the
  resource that declares it, and bounded to the actor's own rows wherever
  there are rows.

  ## Who it admits

  A person (`user_id` in the context), whose account is active (the actor's
  `lifecycle_status` is `:active` — a deactivated account is not a member),
  acting in their own tenant (the call's tenant is the context's
  organization). A generic action asked about with no tenant at all — as
  `ash_acp` prunes its command palette, `Ash.can?/3` with no options — is
  admitted: it has no rows, and everything it does runs under a tenant and
  its own checks (a create or read with no tenant is never admitted, since
  a nil tenant reads across tenants). Each condition is a positive requirement of this path, not a
  `forbid_if`: failing one contributes `false` to the union and takes nothing
  from any other path. System actors contribute nothing here; they have their
  own bypass.

  ## Never queries

  The declaration is compile-time DSL; the actor's id, tenant and status are
  already on the actor and its `ActorContext`.
  """

  use Ash.Policy.FilterCheck

  alias AshEnterprise.Security.ActorContext

  require Ash.Expr
  import Ash.Expr, only: [expr: 1]

  @impl true
  def describe(_opts),
    do: "action is self-service and the actor is an active member acting for themselves"

  @impl true
  def filter(actor, authorizer, _opts) do
    context = ActorContext.for_actor(actor)

    cond do
      context.system? -> false
      is_nil(context.user_id) -> false
      not declared?(authorizer) -> false
      not active?(actor) -> false
      not own_tenant?(context, authorizer) -> false
      authorizer.action.type == :action -> true
      true -> expr(owner_id == ^context.user_id)
    end
  end

  @doc "The actions `resource` declares self-service."
  @spec actions(module()) :: [atom()]
  def actions(resource),
    do: Spark.Dsl.Extension.get_opt(resource, [:platform], :self_service, [])

  defp declared?(%{resource: resource, action: %{name: name}}), do: name in actions(resource)

  defp active?(actor), do: Map.get(actor, :lifecycle_status) == :active

  defp own_tenant?(%{organization_id: nil}, _authorizer), do: false

  defp own_tenant?(%{organization_id: organization_id}, authorizer) do
    case tenant(authorizer) do
      nil -> authorizer.action.type == :action
      tenant -> to_string(tenant) == to_string(organization_id)
    end
  end

  defp tenant(%{subject: %{to_tenant: tenant}}) when not is_nil(tenant), do: tenant
  defp tenant(%{subject: %{tenant: tenant}}), do: tenant
  defp tenant(_authorizer), do: nil
end
