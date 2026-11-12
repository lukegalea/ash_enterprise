defmodule AshEnterprise.Platform.Validations.WithinRestoreWindow do
  @moduledoc """
  A soft-deleted row may be restored only within the restore window after it was archived.

      config :ash_enterprise, AshEnterprise.Platform.Validations.WithinRestoreWindow, days: 30

  Used by a resource's `:restore` action (see `AshEnterprise.Accounts.Team`): the row must
  be archived (`archived_at` set by `ash_archival`'s destroy), and archived no more than
  `days` ago. Past the window the row stays archived, and bringing it back is a new create,
  recorded as one.

  The window is a policy number, not a technical limit: an archived row is kept whatever
  its age. Thirty days covers "I deleted the wrong one" without letting a restore quietly
  revive something everyone has long since stopped expecting to exist.
  """

  use Ash.Resource.Validation

  @default_days 30

  @doc "The restore window, in days."
  @spec days() :: pos_integer()
  def days do
    :ash_enterprise
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:days, @default_days)
  end

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, opts, _context) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    case Map.get(changeset.data, :archived_at) do
      nil ->
        {:error, field: :archived_at, message: "is not archived, so there is nothing to restore"}

      archived_at ->
        if DateTime.diff(now, archived_at, :second) <= days() * 86_400,
          do: :ok,
          else:
            {:error,
             field: :archived_at,
             message: "was archived more than %{days} days ago, outside the restore window",
             vars: [days: days()]}
    end
  end
end
