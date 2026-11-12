defmodule AshEnterprise.Security.Checks.ForeignTenant do
  @moduledoc """
  The call names a tenant other than the one the actor's
  `AshEnterprise.Security.ActorContext` was built for.

  A context is built for one tenant: its role assignments, teams, shares and
  candidate tasks are read in that tenant, and a `:global` grant in it means
  "everything in the tenant", never "everything". Nothing in a grant records which
  tenant it came from, so a context built for one tenant and handed a call that names
  another would let its grants reach the other tenant's rows.

  `AshEnterprise.Security.TenantBoundary` makes this the condition of a policy that
  nothing passes, declared on every platform resource ahead of its bypasses and grant
  union:

      policy AshEnterprise.Security.Checks.ForeignTenant do
        authorize_if never()
      end

  So a call in a foreign tenant is refused, and every other call is untouched: the
  policy does not apply to it, which leaves the union and the bypasses deciding
  exactly as before. It is not row access (it does not ask which records the actor
  may reach, only whether the actor's authority applies in this tenant at all, as a
  decommissioned tenant would), so it sits beside the union rather than in it, and it
  takes nothing from any grant path in the actor's own tenant.

  | Caller | Foreign? |
  |---|---|
  | a system actor or system context (a platform principal) | never: it crosses tenants on purpose |
  | a resource that is not tenant-scoped, or a call with no tenant | never: there is no tenant to compare |
  | no actor, or `ai` (a context with no person and no principal) | never: it carries no grants anywhere |
  | a person, or an automation principal | whenever the call's tenant is not its context's |

  System actors are the platform's own machinery (a cron trigger, a seed, a release
  task) and cross tenants by design. Everything else carries authority some tenant
  gave it, and that authority stays in that tenant.

  ## Never queries

  The tenant is on the call and on the actor's precomputed context.
  """

  use Ash.Policy.SimpleCheck

  alias AshEnterprise.Security.ActorContext

  @impl true
  def describe(_opts),
    do: "the call's tenant is not the one the actor's context was built for"

  @impl true
  def match?(actor, %{resource: resource} = authorizer, _opts) do
    tenant = tenant(authorizer)

    cond do
      is_nil(tenant) -> false
      is_nil(Ash.Resource.Info.multitenancy_strategy(resource)) -> false
      true -> actor |> ActorContext.for_actor() |> foreign?(tenant)
    end
  end

  def match?(_actor, _authorizer, _opts), do: false

  defp foreign?(%ActorContext{system?: true}, _tenant), do: false
  defp foreign?(%ActorContext{user_id: nil, automation: nil}, _tenant), do: false
  defp foreign?(%ActorContext{organization_id: nil}, _tenant), do: true

  defp foreign?(%ActorContext{organization_id: organization_id}, tenant),
    do: to_string(organization_id) != to_string(tenant)

  defp tenant(%{subject: %{to_tenant: tenant}}) when not is_nil(tenant), do: tenant
  defp tenant(%{subject: %{tenant: tenant}}), do: tenant
  defp tenant(_authorizer), do: nil
end
