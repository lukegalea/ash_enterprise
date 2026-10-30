defmodule Battery.Execution.ReadApproval do
  @moduledoc """
  On `apply_decision`: the outcome comes from the row's decided approval task, never
  from the caller. Approved by someone other than the requester: `:approved` (the
  fragment then checks the approval still binds the request); rejected: `:rejected`;
  undecided: refused.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Battery.Bpmn.HumanTask
  alias Battery.Execution.RequestApproval

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &read/1, prepend?: true)
  end

  defp read(changeset) do
    row = changeset.data
    key = RequestApproval.key()
    subject_type = to_string(row.__struct__)

    task =
      HumanTask
      |> Ash.Query.filter(
        subject_type == ^subject_type and subject_id == ^row.id and node_id == ^key
      )
      |> Ash.read_one!(authorize?: false)

    case task do
      %{status: :completed, outcome: "approved", decided_by_id: decider}
      when decider != row.owner_id ->
        outcome(changeset, :approved, decider, task)

      %{status: :completed, outcome: "rejected", decided_by_id: decider} ->
        outcome(changeset, :rejected, decider, task)

      _undecided ->
        Ash.Changeset.add_error(changeset, field: :outcome, message: "no decision to apply")
    end
  end

  defp outcome(changeset, outcome, decider, task) do
    changeset
    |> Ash.Changeset.force_set_argument(:outcome, outcome)
    |> Ash.Changeset.force_set_argument(:decided_by_id, decider)
    |> Ash.Changeset.force_change_attribute(:approval_task_id, task.id)
  end
end
