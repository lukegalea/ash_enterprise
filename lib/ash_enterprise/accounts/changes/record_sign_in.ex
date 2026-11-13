defmodule AshEnterprise.Accounts.Changes.RecordSignIn do
  @moduledoc """
  Records the admission an action makes when it signs the user in, at the door named by
  `door:` (`AshEnterprise.Security.AuthenticationAudit`). For the actions other than
  password sign-in that issue a session token: a password reset and a confirmation.

  Inside the transaction, after the write: if the audit chain cannot hold the admission,
  the action fails and rolls back, and no token leaves it.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Security.AuthenticationAudit

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, user ->
      case AuthenticationAudit.admitted(opts[:door], user.id) do
        :ok -> {:ok, user}
        {:error, error} -> {:error, error}
      end
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
