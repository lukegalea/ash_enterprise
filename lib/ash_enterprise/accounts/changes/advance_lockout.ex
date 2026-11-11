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
    args = %{
      now: Ash.Changeset.get_argument(changeset, :now),
      cutoff: Ash.Changeset.get_argument(changeset, :window_cutoff),
      lock_until: Ash.Changeset.get_argument(changeset, :lock_until),
      max: Ash.Changeset.get_argument(changeset, :max_attempts)
    }

    changeset
    |> Ash.Changeset.force_change_attribute(:failed_count, 1)
    |> Ash.Changeset.force_change_attribute(:window_started_at, args.now)
    |> Ash.Changeset.force_change_attribute(
      :locked_until,
      if(args.max <= 1, do: args.lock_until)
    )
    |> Ash.Changeset.atomic_update(:failed_count, failed_count(args))
    |> Ash.Changeset.atomic_update(:window_started_at, window_started_at(args))
    |> Ash.Changeset.atomic_update(:locked_until, locked_until(args))
  end

  defp locked(%{now: now}), do: expr(not is_nil(locked_until) and locked_until > ^now)

  defp restarts(%{now: now, cutoff: cutoff}) do
    expr((not is_nil(locked_until) and locked_until <= ^now) or window_started_at <= ^cutoff)
  end

  defp failed_count(args) do
    locked = locked(args)
    restarts = restarts(args)

    expr(
      cond do
        ^locked -> failed_count
        ^restarts -> 1
        true -> failed_count + 1
      end
    )
  end

  defp window_started_at(%{now: now} = args) do
    locked = locked(args)
    restarts = restarts(args)

    expr(
      cond do
        ^locked -> window_started_at
        ^restarts -> ^now
        true -> window_started_at
      end
    )
  end

  defp locked_until(%{lock_until: lock_until, max: max} = args) do
    locked = locked(args)
    restarts = restarts(args)

    expr(
      cond do
        ^locked -> locked_until
        ^restarts -> if(^max <= 1, do: ^lock_until, else: nil)
        failed_count + 1 >= ^max -> ^lock_until
        true -> nil
      end
    )
  end
end
