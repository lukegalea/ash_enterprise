defmodule AshEnterprise.AgentSpike.ApplyDecision do
  @moduledoc """
  The `:apply_decision` trigger's check (S6): read the completed approval
  task for this row, and refuse unless it was approved by a person who is not
  the row's owner. Runs inside the trigger's update, as the trigger's actor;
  this is action logic, not a policy check, so it may read.

  The decider is put in the changeset context as `:approved_by_id`, which a
  real host would record in a column.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.AgentSpike.RequestApproval
  alias AshEnterprise.Bpmn.HumanTask

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &check/1)
  end

  defp check(changeset) do
    row = changeset.data
    tenant = changeset.tenant
    subject_type = to_string(row.__struct__)
    key = RequestApproval.key()

    task =
      HumanTask
      |> Ash.Query.filter(
        subject_type == ^subject_type and subject_id == ^row.id and node_id == ^key and
          status == :completed
      )
      |> Ash.Query.sort(updated_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(authorize?: false, tenant: tenant)

    cond do
      is_nil(task) or task.outcome != "approved" ->
        Ash.Changeset.add_error(changeset, "no approved decision for this row")

      is_nil(task.decided_by_id) or task.decided_by_id == row.owner_id ->
        Ash.Changeset.add_error(changeset, "the decider must be a person other than the owner")

      not person?(task.decided_by_id) ->
        Ash.Changeset.add_error(changeset, "the decider must be a person")

      true ->
        Ash.Changeset.set_context(changeset, %{approved_by_id: task.decided_by_id})
    end
  end

  defp person?(id) do
    User
    |> Ash.Query.filter(id == ^id)
    |> Ash.exists?(authorize?: false)
  end
end
