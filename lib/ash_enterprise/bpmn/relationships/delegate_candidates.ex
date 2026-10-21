defmodule AshEnterprise.Bpmn.Relationships.DelegateCandidates do
  @moduledoc """
  `HumanTask.delegate_candidates`: for each task, the people its holder may
  hand it to — `AshEnterprise.Accounts.User.delegate_candidates`, read as the
  loading actor, so the relationship and the board's Delegate picker give
  the same answer.

  One read per task: it exists to name the picker's destination and to answer
  for one task, not to be loaded across a list.
  """

  use Ash.Resource.ManualRelationship

  alias AshEnterprise.Accounts.User

  @impl true
  def load(tasks, _opts, context) do
    opts = Ash.Context.to_opts(context)

    Enum.reduce_while(tasks, {:ok, %{}}, fn task, {:ok, acc} ->
      User
      |> Ash.Query.for_read(:delegate_candidates, %{task_id: task.id}, opts)
      |> Ash.read()
      |> case do
        {:ok, users} -> {:cont, {:ok, Map.put(acc, task.id, users)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end
end
