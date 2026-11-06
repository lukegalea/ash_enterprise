defmodule AshEnterprise.Credentialing.RegistryDisclosureGate do
  @moduledoc """
  The decision on whether `RegistryApi.activate` may send a licence number to the registry
  (`AshOperations.DisclosureGate`). Leaving the zone is a disclosure (ADR 0026, narrowed by
  ADR 0042), so this answers on this host's zone model, never from the payload:

    1. The tenant is the action's own (`context.tenant`). With none the answer is
       `"no_tenant"`.
    2. The actor must be able to read the credential that `disclosure_ref` names, in that
       tenant: the record that justifies the send. Otherwise `"ref_unreadable"`.
    3. `AshEnterprise.Zones.ResidencyPolicy.allow?/3` decides on the registry's residency
       (`RegistryApi.Transport.residency/0`): an in-cluster registry is allowed; a sub-processor
       only when the tenant recorded an opt-in and the in-zone flow guard is off. Otherwise
       `"residency_denied"`.

  It writes nothing. The governed invocation records a refusal: the invocation fails with
  the `denied` failure class and the code, and its row is audited.

  This gate runs in the action path, not in a policy check, so the credential read it makes
  is allowed (non-negotiable 3 binds policy checks only), as `ResidencyPolicy`'s own read is.
  """

  @behaviour AshOperations.DisclosureGate

  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.RegistryApi.Transport
  alias AshEnterprise.Zones.ResidencyPolicy

  @impl AshOperations.DisclosureGate
  def authorize(%{disclosure_ref: ref}, context) do
    tenant = Map.get(context, :tenant)

    with {:ok, tenant} <- tenant_of(tenant),
         :ok <- readable(ref, Map.get(context, :actor), tenant) do
      residency(tenant)
    end
  end

  defp tenant_of(nil), do: {:error, "no_tenant"}
  defp tenant_of(tenant), do: {:ok, tenant}

  defp readable(ref, actor, tenant) do
    case Credentialing.get_credential(ref, actor: actor, tenant: tenant, not_found_error?: false) do
      {:ok, %{}} -> :ok
      _unreadable -> {:error, "ref_unreadable"}
    end
  rescue
    # A reference that is not a UUID can name nothing readable.
    _malformed -> {:error, "ref_unreadable"}
  end

  defp residency(tenant) do
    if ResidencyPolicy.allow?(tenant, Transport.residency(), :credential_registry),
      do: :ok,
      else: {:error, "residency_denied"}
  end
end
