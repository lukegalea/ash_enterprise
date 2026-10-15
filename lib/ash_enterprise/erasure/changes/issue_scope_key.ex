defmodule AshEnterprise.Erasure.Changes.IssueScopeKey do
  @moduledoc """
  Issues a new scope's one key, inside the transaction that creates the scope.

  An `after_action` hook rather than a separate call so that a scope without a
  key cannot commit: if issuing fails (no master key configured, a fingerprint
  collision), the scope insert rolls back with it. A scope that existed with no
  key would read as a lost key — which `AshEnterprise.Erasure.Keyring` treats as
  an incident — rather than as an empty scope.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Erasure.Keyring

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, scope ->
      _key = Keyring.issue!(scope)
      {:ok, scope}
    end)
  end
end
