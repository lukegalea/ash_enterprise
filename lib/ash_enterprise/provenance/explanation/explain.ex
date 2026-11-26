defmodule AshEnterprise.Provenance.Explanation.Explain do
  @moduledoc """
  `AshEnterprise.Provenance.Explanation`'s `explain`: refuses a call with no
  tenant and dispatches `AshEnterprise.Provenance.Walk`.

  A walk is read in one tenant, and refused without one, for the reason
  `AshEnterprise.Execution.Entry.Trace` is: the records it reads are
  organization-scoped, and a read with no tenant applies no organization
  filter, so a grant that reaches everything in a tenant (a tenant
  Administrator's `:global`) would otherwise reach every tenant's rows under
  the address given.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Provenance.Explanation
  alias AshEnterprise.Provenance.Walk

  @impl true
  def run(_input, _opts, %{tenant: nil}),
    do: {:error, Ash.Error.Invalid.TenantRequired.exception(resource: Explanation)}

  def run(input, _opts, context) do
    Walk.explain(input.arguments.address, actor: context.actor, tenant: context.tenant)
  end
end
