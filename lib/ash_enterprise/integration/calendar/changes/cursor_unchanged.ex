defmodule AshEnterprise.Integration.Calendar.Changes.CursorUnchanged do
  @moduledoc """
  Compare-and-set for `SyncCursor` writes. The update applies only if the row
  still holds what the writer read: `expected_sync_token`,
  `expected_page_token` and `expected_reset_count`. If the row has moved on
  (an operator reset, or another step advancing the same cursor), the write
  matches no row and fails with `Ash.Error.Changes.StaleRecord`. It does not
  overwrite the newer state.

  `reset_count` is part of the comparison so that a reset is never undone, even
  when it leaves the tokens looking exactly as the writer read them (nil and
  nil at the start of a full pass).

  A nil `expected_reset_count` means the write is unconditional. Only the
  operator's explicit reset (`Sync.reset_sync`) writes that way: it is meant to
  win over whatever a step is doing.

  The comparison is a filter on the UPDATE itself, so it is atomic. There is no
  read-then-write window.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context), do: guard(changeset)

  @impl true
  def atomic(changeset, _opts, _context), do: {:ok, guard(changeset)}

  defp guard(changeset) do
    case Ash.Changeset.get_argument(changeset, :expected_reset_count) do
      nil ->
        changeset

      count ->
        Ash.Changeset.filter(changeset,
          reset_count: [eq: count],
          sync_token: token(Ash.Changeset.get_argument(changeset, :expected_sync_token)),
          page_token: token(Ash.Changeset.get_argument(changeset, :expected_page_token))
        )
    end
  end

  defp token(nil), do: [is_nil: true]
  defp token(value), do: [eq: value]
end
