defmodule AshEnterprise.Bpmn.Subscription.Validations.TenantScopedMatch do
  @moduledoc """
  Refuses a subscription on a resource with no tenant, whatever its authority.

  A recipe fires on a committed row in a tenant's audit chain. A resource declared
  `tenant?: false` (a `User`, say) writes into no tenant's chain, and the sweep reads only
  tenants' chains, so a subscription on one would publish and never fire. Such events reach
  recipes through a tenant-scoped occurrence instead.

  A name that does not resolve to a resource is left to the library's own check, which
  refuses it with a better message.
  """

  use Ash.Resource.Validation

  alias AshBpmn.Resources.Subscription.ResourceName

  @impl true
  def validate(changeset, _opts, _context) do
    with name when is_binary(name) <- Ash.Changeset.get_attribute(changeset, :match_resource),
         {:ok, resource} <- ResourceName.resolve(name),
         nil <- Ash.Resource.Info.multitenancy_strategy(resource) do
      {:error,
       field: :match_resource,
       message:
         "a subscription may not match #{ResourceName.short(name)}: it has no tenant, so " <>
           "its writes land in no tenant's audit chain and nothing would ever sweep them"}
    else
      _ -> :ok
    end
  end
end
