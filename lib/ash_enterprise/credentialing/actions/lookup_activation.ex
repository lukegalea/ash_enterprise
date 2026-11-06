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
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.Registry
  alias AshEnterprise.Faults

  @effect_system "credential-registry"

  @impl true
  def run(input, _opts, context) do
    with {:ok, credential} <-
           Credentialing.get_credential(input.arguments.id, Ash.Context.to_opts(context)),
         :ok <- Faults.point(:credential_registry_lookup),
         {:ok, answer} <- Registry.lookup(credential.id) do
      {:ok,
       %{
         "outcome" => outcome(answer.status),
         "effect_ref" => answer.reference,
         "effect_system" => @effect_system
       }}
    end
  end

  defp outcome(:active), do: "succeeded"
  defp outcome(:unknown), do: "unknown"
end
