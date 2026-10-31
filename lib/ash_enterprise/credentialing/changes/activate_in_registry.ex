defmodule AshEnterprise.Credentialing.Changes.ActivateInRegistry do
  @moduledoc """
  `activate_credential`'s work: ask the registry to activate the credential, then record
  its reference and mark the credential active.

  The registry is called before the update's transaction opens, so no transaction is
  held while the call is out. A credential that is already active keeps the time it was
  first activated. A registry failure is added to the changeset as the typed
  `AshEnterprise.Credentialing.RegistryError`, which the invocation classifies.

  The fault point `:credential_registry_accepted` sits between the registry accepting
  the activation and anything being recorded here (`AshEnterprise.Faults`): the moment
  failure scenario F2 is about.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Credentialing.Registry
  alias AshEnterprise.Faults

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_transaction(changeset, &activate/1)
  end

  defp activate(changeset) do
    credential = changeset.data

    case Registry.activate(credential.id) do
      {:ok, reference} ->
        Faults.point(:credential_registry_accepted)

        Ash.Changeset.force_change_attributes(changeset, %{
          status: :active,
          registry_reference: reference,
          activated_at: credential.activated_at || DateTime.utc_now()
        })

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end
end
