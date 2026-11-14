defmodule AshEnterprise.Accounts.Changes.DiscardProviderTokens do
  @moduledoc """
  Empties the provider tokens `AshAuthentication.UserIdentity.UpsertIdentityChange`
  copies onto a `AshEnterprise.Accounts.UserIdentity` row.

  This application uses the identity provider to sign people in and calls nothing on
  their behalf, so it has no use for the provider's access or refresh token. Keeping
  them would put a credential for another system in a plaintext column. Declare it
  after the upsert change.
  """

  use Ash.Resource.Change

  @fields [:access_token, :access_token_expires_at, :refresh_token]

  @impl true
  def change(changeset, _opts, _context) do
    Enum.reduce(@fields, changeset, &Ash.Changeset.force_change_attribute(&2, &1, nil))
  end
end
