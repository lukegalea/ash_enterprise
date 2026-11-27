defmodule AshEnterprise.Accounts.Validations.NotSelf do
  @moduledoc """
  Refuses `AshEnterprise.Accounts.User`'s `:deactivate` when the actor is the user
  being deactivated.

  Deactivating revokes the user's tokens (`Changes.RevokeTokensOnDeactivation`), so
  an administrator who deactivated themselves would be sent to sign in on their next
  action and could not sign back in to undo it. Another administrator does it
  instead. An action run with no actor (a seed, a system job) is not refused.
  """

  use Ash.Resource.Validation
  use Gettext, backend: AshEnterpriseWeb.Gettext

  @impl true
  def validate(changeset, _opts, %{actor: %{id: id}}) when not is_nil(id) do
    if Ash.Changeset.get_data(changeset, :id) == id do
      {:error,
       Ash.Error.Changes.InvalidChanges.exception(
         message:
           dgettext_noop(
             "errors",
             "You cannot deactivate your own account. Ask another administrator to do it."
           )
       )}
    else
      :ok
    end
  end

  def validate(_changeset, _opts, _context), do: :ok
end
