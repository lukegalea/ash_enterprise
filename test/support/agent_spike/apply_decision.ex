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

  @not_the_owner "the decider must be a person other than the owner"

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &check/1)
  end

  defp check(changeset) do
    case changeset.data |> approval_task(changeset.tenant) |> verdict(changeset.data) do
      {:ok, decider_id} -> Ash.Changeset.set_context(changeset, %{approved_by_id: decider_id})
      {:error, message} -> Ash.Changeset.add_error(changeset, message)
    end
  end

  defp approval_task(row, tenant) do
    subject_type = to_string(row.__struct__)
    key = RequestApproval.key()

    HumanTask
    |> Ash.Query.filter(
      subject_type == ^subject_type and subject_id == ^row.id and node_id == ^key and
        status == :completed
    )
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false, tenant: tenant)
  end

  defp verdict(%{outcome: "approved", decided_by_id: decider_id}, row)
       when not is_nil(decider_id) do
    cond do
      decider_id == row.owner_id -> {:error, @not_the_owner}
      person?(decider_id) -> {:ok, decider_id}
      true -> {:error, "the decider must be a person"}
    end
  end

  defp verdict(%{outcome: "approved"}, _row), do: {:error, @not_the_owner}
  defp verdict(_task, _row), do: {:error, "no approved decision for this row"}

  defp person?(id) do
    User
    |> Ash.Query.filter(id == ^id)
    |> Ash.exists?(authorize?: false)
  end
end
