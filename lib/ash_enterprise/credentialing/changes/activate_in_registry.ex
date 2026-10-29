defmodule AshEnterprise.Credentialing.Changes.ActivateInRegistry do
  @moduledoc """
  `activate_credential`'s work: ask the registry to activate the credential, then record
  its reference and mark the credential active.

  The registry is called before the update's transaction opens, so no transaction is
  held while the call is out. A credential that is already active keeps the time it was
  first activated.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Credentialing.Registry

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_transaction(changeset, &activate/1)
  end

  defp activate(changeset) do
    credential = changeset.data
    {:ok, reference} = Registry.activate(credential.id)

    Ash.Changeset.force_change_attributes(changeset, %{
      status: :active,
      registry_reference: reference,
      activated_at: credential.activated_at || DateTime.utc_now()
    })
  end
end
