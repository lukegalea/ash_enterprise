defmodule AshEnterprise.Accounts.Validations.NoManagerCycle do
  @moduledoc """
  Rejects a management chain that loops back on itself.

  Without this, `AshEnterprise.Security.Hierarchy`'s descendant walk would either
  not terminate or — because it is depth-bounded — terminate having computed a
  *wrong* subordinate set. The second is the dangerous one: it produces incorrect
  authorization with no error anywhere.

  Cycles are also possible without anyone doing anything obviously silly: A
  manages B, then a reorganization makes B manage A, and each edit looks
  reasonable on its own.
  """

  use Ash.Resource.Validation

  require Ash.Query

  @max_walk 64

  @impl true
  def validate(changeset, _opts, _context) do
    id = changeset.data && Map.get(changeset.data, :id)
    manager_id = Ash.Changeset.get_attribute(changeset, :manager_id)

    cond do
      is_nil(manager_id) -> :ok
      is_nil(id) -> :ok
      manager_id == id -> invalid("a user cannot be their own manager")
      id in chain_from(manager_id) -> invalid("this would create a management cycle")
      true -> :ok
    end
  end

  # Walk upward from `start_id`, collecting everyone in the chain.
  defp chain_from(start_id) do
    Enum.reduce_while(1..@max_walk//1, {[], start_id}, fn _, {acc, current} ->
      case current && fetch_manager(current) do
        nil -> {:halt, {[current | acc], nil}}
        manager_id -> {:cont, {[current | acc], manager_id}}
      end
    end)
    |> elem(0)
    |> Enum.reject(&is_nil/1)
  end

  defp fetch_manager(user_id) do
    AshEnterprise.Accounts.User
    |> Ash.Query.filter(id == ^user_id)
    |> Ash.Query.select([:id, :manager_id])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{manager_id: manager_id}} -> manager_id
      _ -> nil
    end
  end

  defp invalid(message) do
    {:error, Ash.Error.Changes.InvalidAttribute.exception(field: :manager_id, message: message)}
  end
end
