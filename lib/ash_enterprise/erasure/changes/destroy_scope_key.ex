defmodule AshEnterprise.Erasure.Changes.DestroyScopeKey do
  @moduledoc """
  The shred itself: deletes the scope's key row, in the same transaction that
  marks the scope `:shredded`.

  Same transaction, so the two facts cannot disagree. A scope marked shredded
  whose key survived would read as erased while still being decryptable by
  anyone holding the master key; a key deleted under a scope still marked
  active would read as a lost key. Either outcome is worse than a failed shred,
  so a shred that cannot find a key to destroy fails and rolls back.

  The same transaction deletes the derived joins of the rows sealed under the
  scope (`AshEnterprise.Canonical.Derive.forget_scope/1`): they carry ids, not
  sealed values, so the key's destruction alone would leave who-meets-whom
  readable.

  The `DELETE` is a real one (`Key` is not archivable). What it does not reach —
  dead tuples before `VACUUM`, WAL, backups, replicas — is listed in
  `docs/runbooks/crypto-shredding.md`. Each of those still holds only the
  *wrapped* key, which is useless without the master key.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Erasure.Key

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, scope ->
      case Key.for_scope(scope.id, authorize?: false) do
        {:ok, %Key{} = key} ->
          :ok = Key.destroy_for_shred!(key, authorize?: false)
          forget_derived(scope)

        {:ok, nil} ->
          {:error,
           Ash.Error.Changes.InvalidChanges.exception(
             message:
               "erasure scope #{scope.id} has no key to destroy; refusing to mark it shredded"
           )}

        {:error, error} ->
          {:error, error}
      end
    end)
  end

  # The derived joins (who attends which event, who takes part in which
  # conversation) hold ids, not sealed values, so destroying the key does not
  # reach them: they are deleted, in the same transaction, for every event and
  # conversation sealed under this scope.
  defp forget_derived(scope) do
    case AshEnterprise.Canonical.Derive.forget_scope(scope.id) do
      :ok ->
        {:ok, scope}

      {:error, {resource, reason}} ->
        {:error,
         Ash.Error.Changes.InvalidChanges.exception(
           message: "could not delete #{inspect(resource)} rows for the shred (#{reason})"
         )}
    end
  end
end
