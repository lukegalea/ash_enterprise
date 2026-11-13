defmodule AshEnterprise.Accounts.Changes.RecordApiKeyIssue do
  @moduledoc """
  After an API key's `:issue` commits, records the fact in each organization its owner
  belongs to (`AshEnterprise.Automation.Occurrences.api_key_issued/1`), because `ApiKey` is
  `tenant?: false` and its own audit row lands in the chain no sweep reads.

  After the transaction, not inside it: the occurrence is detective, so it can never veto
  or roll back the issue, and a failed write is logged and nothing more. The occurrence
  carries the key's id and expiry, never the key.
  """
  use Ash.Resource.Change

  alias AshEnterprise.Automation.Occurrences

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, key} = result ->
        Occurrences.api_key_issued(key)
        result

      _changeset, result ->
        result
    end)
  end
end
