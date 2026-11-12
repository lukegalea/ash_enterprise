defmodule AshEnterprise.Security.Checks.ManagesRecipes do
  @moduledoc """
  A grant path for what a recipe's administrator does around the recipes themselves:
  authorizes a person who holds a global `write` on `AshEnterprise.Bpmn.Subscription` in the
  tenant of the call, the grant that publishing, enabling and disabling that tenant's recipes
  already needs.

  Added through `extra_grants:` (so one more `authorize_if` in the union, never a way out) by
  `AshEnterprise.Bpmn.Redrive`, whose re-drive of a failed dispatch is the same decision as
  switching a recipe back on for one event. A separate privilege on the re-drive resource
  would be one more thing to grant to the same people, and to forget.

  ## Who it admits

  A person (`user_id` in the context), whose account is active, acting in their own tenant.
  Never a system actor (they have their own bypass, narrowed per action) and never an
  automation principal, even acting for a person who holds the grant (ADR 0043). Each
  condition is a positive requirement of this path, not a `forbid_if`: failing one
  contributes `false` and takes nothing from any other path.

  ## Never queries

  The grant comes from the precomputed `ActorContext`.
  """

  use Ash.Policy.SimpleCheck

  alias AshEnterprise.Security.ActorContext

  @impl true
  def describe(_opts),
    do: "actor is an active person holding a global write on this tenant's recipes"

  @impl true
  def match?(actor, authorizer, _opts) do
    context = ActorContext.for_actor(actor)

    not context.system? and is_nil(context.automation) and not is_nil(context.user_id) and
      Map.get(actor, :lifecycle_status) == :active and own_tenant?(context, authorizer) and
      ActorContext.grant(context, AshEnterprise.Bpmn.Subscription, :write).global?
  end

  defp own_tenant?(%{organization_id: nil}, _authorizer), do: false

  defp own_tenant?(%{organization_id: organization_id}, authorizer) do
    case tenant(authorizer) do
      nil -> false
      tenant -> to_string(tenant) == to_string(organization_id)
    end
  end

  defp tenant(%{subject: %{to_tenant: tenant}}) when not is_nil(tenant), do: tenant
  defp tenant(%{subject: %{tenant: tenant}}), do: tenant
  defp tenant(_authorizer), do: nil
end
