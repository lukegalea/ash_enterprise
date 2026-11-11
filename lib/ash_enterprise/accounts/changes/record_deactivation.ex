defmodule AshEnterprise.Accounts.Changes.RecordDeactivation do
  @moduledoc """
  After a user's `:deactivate` commits, records the fact in each organization the user
  belongs to (`AshEnterprise.Automation.Occurrences.user_deactivated/1`), because `User`
  is `tenant?: false` and its own audit row lands in the chain no sweep reads.

  After the transaction, not inside it: the occurrence is detective, so it can never
  veto or roll back the deactivation, and a failed write is logged and nothing more.
  """
  use Ash.Resource.Change

  alias AshEnterprise.Automation.Occurrences

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, user} = result ->
        Occurrences.user_deactivated(user)
        result

      _changeset, result ->
        result
    end)
  end
end
