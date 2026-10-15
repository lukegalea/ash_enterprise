defmodule AshEnterprise.Integration.Gmail.Changes.EnqueueSync do
  @moduledoc """
  Enqueues one `AshEnterprise.Integration.Gmail.SyncWorker` step for the
  cursor row just written, inside the action's transaction: the job exists iff
  the row does.

  Job args are ids only, string-keyed (Iron Laws #08, #09): the owning user and
  the linked account. The worker's uniqueness collapses a second request while
  a step is still queued or running.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Integration.Gmail.SyncWorker

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, sync_state ->
      sync_state
      |> SyncWorker.args()
      |> SyncWorker.new()
      |> Oban.insert()
      |> case do
        {:ok, _job} -> {:ok, sync_state}
        {:error, error} -> {:error, error}
      end
    end)
  end
end
