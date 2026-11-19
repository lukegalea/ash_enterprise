defmodule AshEnterprise.Integration.Outbound.DisclosureGate do
  @moduledoc """
  The decision on whether `Outbound.Receiver.deliver` may send to an endpoint
  (`AshOperations.DisclosureGate`). It reads the host's own records, never the payload:

    1. The tenant is the call's own (`context.tenant`). With none: `"no_tenant"`.
    2. The endpoint that `disclosure_ref` names exists in that tenant: otherwise
       `"endpoint_unknown"` (another tenant's endpoint is unknown here).
    3. It is active: otherwise `"endpoint_inactive"`.
    4. The zone residency policy allows a tenant-designated destination for the tenant
       (`AshEnterprise.Zones.ResidencyPolicy`, class `:tenant_designated`): the tenant's own
       registration is its recorded authorization. Otherwise `"residency_denied"`.

  It writes nothing; the delivery records a refusal. It runs in the action path, not in a
  policy check, so the endpoint read it makes is allowed (non-negotiable 3 binds policy
  checks only).
  """

  @behaviour AshOperations.DisclosureGate

  alias AshEnterprise.Integration.Outbound.Endpoint
  alias AshEnterprise.Zones.ResidencyPolicy

  @impl AshOperations.DisclosureGate
  def authorize(%{disclosure_ref: ref}, context) do
    with {:ok, tenant} <- tenant_of(Map.get(context, :tenant)),
         {:ok, endpoint} <- endpoint(tenant, ref),
         :ok <- active(endpoint) do
      if ResidencyPolicy.allow?(tenant, :tenant_designated, :webhook),
        do: :ok,
        else: {:error, "residency_denied"}
    end
  end

  defp tenant_of(nil), do: {:error, "no_tenant"}
  defp tenant_of(tenant), do: {:ok, tenant}

  defp endpoint(tenant, ref) do
    with {:ok, id} <- Ecto.UUID.cast(ref),
         {:ok, %Endpoint{organization_id: ^tenant} = endpoint} <-
           Ash.get(Endpoint, id, tenant: tenant, authorize?: false) do
      {:ok, endpoint}
    else
      _ -> {:error, "endpoint_unknown"}
    end
  end

  defp active(%Endpoint{status: :active}), do: :ok
  defp active(_endpoint), do: {:error, "endpoint_inactive"}
end
