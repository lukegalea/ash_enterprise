defmodule AshEnterprise.Integration.Outbound.Tenants do
  @moduledoc """
  The tenants the outbound fan-out runs for: every organization with an active endpoint
  (`AshOban.ListTenants`). A tenant with none costs nothing. A cross-tenant read of ids
  only, answering "does anyone listen"; the per-tenant work runs inside each tenant.
  """

  @behaviour AshOban.ListTenants

  require Ash.Query

  alias AshEnterprise.Integration.Outbound.Endpoint

  @impl true
  def list_tenants(_opts) do
    Endpoint
    |> Ash.Query.filter(status == :active)
    |> Ash.Query.select(:organization_id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.organization_id)
    |> Enum.uniq()
  end
end
