defmodule AshEnterprise.Security.Changes.StampBreakGlassWindow do
  @moduledoc """
  Sets `started_at` to now and `expires_at` to `duration_minutes` later.

  A missing or non-positive duration sets neither, so the required attributes
  fail rather than a session with no end being stored.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_argument(changeset, :duration_minutes) do
      minutes when is_integer(minutes) and minutes > 0 ->
        started = DateTime.utc_now()

        changeset
        |> Ash.Changeset.force_change_attribute(:started_at, started)
        |> Ash.Changeset.force_change_attribute(
          :expires_at,
          DateTime.add(started, minutes * 60, :second)
        )

      _ ->
        changeset
    end
  end
end
