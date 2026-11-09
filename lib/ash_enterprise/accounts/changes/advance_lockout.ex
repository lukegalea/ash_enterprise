defmodule AshEnterprise.Accounts.Changes.AdvanceLockout do
  @moduledoc """
  The counting rule of `AshEnterprise.Accounts.SignInLockout.record_failure`.

  On insert the row starts at one failure. On conflict the same rule runs in
  SQL against the stored row, so concurrent failures each add exactly one:

    * locked (`locked_until > now`): nothing changes;
    * a lapsed lock, or a window that has run out: the count restarts at 1;
    * otherwise the count goes up by one, and reaching the limit sets `locked_until`.
  """
  use Ash.Resource.Change

  require Ash.Expr
  import Ash.Expr

  @impl true
  def change(changeset, _opts, _context) do
    now = Ash.Changeset.get_argument(changeset, :now)
    cutoff = Ash.Changeset.get_argument(changeset, :window_cutoff)
    lock_until = Ash.Changeset.get_argument(changeset, :lock_until)
    max = Ash.Changeset.get_argument(changeset, :max_attempts)

    locked = expr(not is_nil(locked_until) and locked_until > ^now)
    lapsed = expr(not is_nil(locked_until) and locked_until <= ^now)
    out_of_window = expr(window_started_at <= ^cutoff)

    changeset
    |> Ash.Changeset.force_change_attribute(:failed_count, 1)
    |> Ash.Changeset.force_change_attribute(:window_started_at, now)
    |> Ash.Changeset.force_change_attribute(:locked_until, if(max <= 1, do: lock_until))
    |> Ash.Changeset.atomic_update(
      :failed_count,
      expr(
        cond do
          ^locked -> failed_count
          ^lapsed or ^out_of_window -> 1
          true -> failed_count + 1
        end
      )
    )
    |> Ash.Changeset.atomic_update(
      :window_started_at,
      expr(
        cond do
          ^locked -> window_started_at
          ^lapsed or ^out_of_window -> ^now
          true -> window_started_at
        end
      )
    )
    |> Ash.Changeset.atomic_update(
      :locked_until,
      expr(
        cond do
          ^locked -> locked_until
          ^lapsed or ^out_of_window -> if(^max <= 1, do: ^lock_until, else: nil)
          failed_count + 1 >= ^max -> ^lock_until
          true -> nil
        end
      )
    )
  end
end
