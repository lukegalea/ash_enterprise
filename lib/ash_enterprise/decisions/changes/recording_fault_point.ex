defmodule AshEnterprise.Decisions.Changes.RecordingFaultPoint do
  @moduledoc """
  A named fault point in the write of a decision's `Evaluation` row,
  `:decision_evaluation_recording`, so a test can make the write fail and check that a
  path which requires the row (`record: :required`) fails with it.

  Fault points do nothing outside the test configuration (`AshEnterprise.Faults`).
  """

  use Ash.Resource.Change

  alias AshEnterprise.Faults

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      Faults.point(:decision_evaluation_recording)
      changeset
    end)
  end
end
