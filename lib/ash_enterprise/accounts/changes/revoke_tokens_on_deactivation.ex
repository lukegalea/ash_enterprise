defmodule AshEnterprise.Accounts.Changes.RevokeTokensOnDeactivation do
  @moduledoc """
  Revokes every stored token of a user in the same transaction that deactivates
  them.

  Filtering deactivated users out of `get_by_subject` already stops a token from
  authenticating. Revoking as well means the token stays dead when the user is
  activated again, and a token reaching a path that does not look the user up
  fails its revocation check.
  """
  use Ash.Resource.Change

  alias AshEnterprise.Accounts.Token

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, user ->
      subject = AshAuthentication.user_to_subject(user)

      result =
        Ash.bulk_update(Token, :revoke_all_stored_for_subject, %{subject: subject},
          strategy: [:atomic, :atomic_batches, :stream],
          context: %{private: %{ash_authentication?: true}},
          return_errors?: true,
          stop_on_error?: true,
          authorize?: false
        )

      case result do
        %{status: :success} -> {:ok, user}
        %{errors: errors} -> {:error, errors}
      end
    end)
  end
end
