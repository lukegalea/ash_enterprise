defmodule AshEnterprise.Execution.Changes.HandoffFaultPoints do
  @moduledoc """
  Two named fault points around the durable handoff of a new invocation (invariant 1):
  a ready row and its `:execute` job commit together or not at all.

    * `:invocation_request_enqueued` fires inside the request's transaction, after the
      fragment's own hook has enqueued the job, so a test can fail the transaction
      after the job's insert and check that neither survives.
    * `:invocation_request_committed` fires after the transaction committed, so a test
      can kill the requester the moment it did and check that the row's job still runs.

  Fault points do nothing outside the test configuration (`AshEnterprise.Faults`). This
  change's hooks are registered after the fragment's, because a resource's own changes
  run after an action's, so they run after the enqueue.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Faults

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.after_action(fn _changeset, row ->
      Faults.point(:invocation_request_enqueued)
      {:ok, row}
    end)
    |> Ash.Changeset.after_transaction(fn _changeset, result ->
      Faults.point(:invocation_request_committed)
      result
    end)
  end
end
