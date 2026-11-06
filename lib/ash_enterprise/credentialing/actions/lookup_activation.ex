defmodule AshEnterprise.Credentialing.Actions.LookupActivation do
  @moduledoc """
  `lookup_activation`: what the registry says about one credential's activation, in the
  shape a `reconcile_with` lookup answers (`AshAgent.Invocation.Target.lookup/4`):

      %{"outcome" => "succeeded" | "unknown",
        "effect_ref" => reference | nil,
        "effect_system" => "credential-registry"}

  Its input is `id`, the credential's id under the name `activate_credential`'s
  arguments carry it, so reconciliation passes it straight through. The credential is
  read as the caller first, so the action answers only about a credential the caller
  may read.

  The fault point `:credential_registry_lookup` sits before the registry is asked
  (`AshEnterprise.Faults`): a lookup that cannot be answered, which leaves an unknown
  outcome for a person to settle.

  It asks the registry through `AshOperations.Reconcile.find/5`, which runs the declared
  `reconcile_with` read of `RegistryApi.activate` (`list_activations`) and never re-sends
  the activation. One match is `succeeded`; none is `unknown`, because absence is not proof
  that the registry never accepted one; several are `unknown` with `reconcile_many`, which is
  left to a person.

  The registry read is made with authorization off, on purpose: `lookup_activation` was itself
  authorized as an action on the credential (the caller can read it), the registry's operations
  are operator-only and reached otherwise only by the governed act
  (`AshEnterprise.Security.Checks.GovernedCall`), and a read-only answer about a credential the
  caller may already read adds no access.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.RegistryApi
  alias AshEnterprise.Faults

  @effect_system "credential-registry"

  @impl true
  def run(input, _opts, context) do
    opts = Ash.Context.to_opts(context)

    with {:ok, credential} <- Credentialing.get_credential(input.arguments.id, opts),
         :ok <- Faults.point(:credential_registry_lookup) do
      reference = RegistryApi.reference(credential.organization_id, credential.id)

      case find(reference, Keyword.put(opts, :authorize?, false)) do
        {:ok, activation} -> {:ok, answer("succeeded", activation["id"])}
        :none -> {:ok, answer("unknown", nil)}
        {:many, _activations} -> {:ok, answer("unknown", nil, "reconcile_many")}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp find(reference, opts) do
    AshOperations.Reconcile.find(
      RegistryApi,
      :activate,
      %{reference: reference},
      fn body -> Enum.filter(body["data"] || [], &(&1["subjectReference"] == reference)) end,
      opts
    )
  end

  defp answer(outcome, effect_ref, code \\ nil) do
    %{
      "outcome" => outcome,
      "effect_ref" => effect_ref,
      "effect_system" => @effect_system
    }
    |> then(&if(code, do: Map.put(&1, "code", code), else: &1))
  end
end
