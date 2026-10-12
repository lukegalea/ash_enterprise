defmodule AshEnterprise.Integration.Gmail.Changes.CountReset do
  @moduledoc """
  Increments `reset_count` on a sync reset.

  Not `atomic_update/2`: the audit wrapper (`AshEvents`) refuses atomic
  changes, because the event it records must carry the value written. The
  row is already loaded by the caller (a reset is always of a row in hand),
  so reading the current count costs nothing.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    count = Map.get(changeset.data, :reset_count) || 0
    Ash.Changeset.force_change_attribute(changeset, :reset_count, count + 1)
  end
end
