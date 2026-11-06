defmodule AshEnterprise.Credentialing.Changes.ActivateInRegistry do
  @moduledoc """
  `activate_credential`'s work: ask the registry to activate the credential, then record
  its reference and mark the credential active.

  The registry is called before the update's transaction opens, so no transaction is
  held while the call is out. A credential that is already active keeps the time it was
  first activated. The call is `RegistryApi.activate/2`, made with the invocation's own
  context so its grant admits it (`AshEnterprise.Security.Checks.GovernedCall`); a failure is
  added to the changeset as the typed `AshOperations.Error`, which the invocation classifies
  (`AshAgent.FailureClass`, `AshEnterprise.Integration.Operations.FailureClass`). A call
  whose answer was lost is `:ambiguous`: the invocation is left `outcome_unknown` and
  reconciled through `lookup_activation`, never re-sent.

  The fault point `:credential_registry_accepted` sits between the registry accepting
  the activation and anything being recorded here (`AshEnterprise.Faults`): the moment
  failure scenario F2 is about.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Credentialing.RegistryApi
  alias AshEnterprise.Faults

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_transaction(changeset, &activate(&1, context))
  end

  defp activate(changeset, context) do
    credential = changeset.data

    arguments = %{
      reference: RegistryApi.reference(changeset.tenant, credential.id),
      licence_number: credential.number,
      disclosure_ref: credential.id
    }

    opts = RegistryApi.governed_opts(context, changeset.context[:ash_agent])

    case RegistryApi.activate(arguments, opts) do
      {:ok, %{"id" => reference}} when is_binary(reference) ->
        Faults.point(:credential_registry_accepted)

        Ash.Changeset.force_change_attributes(changeset, %{
          status: :active,
          registry_reference: reference,
          activated_at: credential.activated_at || DateTime.utc_now()
        })

      {:ok, _unrecognised} ->
        Ash.Changeset.add_error(
          changeset,
          AshOperations.Error.exception(
            reason: :bad_request,
            provider: :credential_registry,
            operation: :activate
          )
        )

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end
end
