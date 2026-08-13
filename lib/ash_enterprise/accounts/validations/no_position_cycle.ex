defmodule AshEnterprise.Accounts.Validations.NoPositionCycle do
  @moduledoc """
  Rejects a position whose parent chain would loop back to itself.

  A cycle here is worse than an error: the descendant walk in
  `AshEnterprise.Security.Hierarchy` would either run forever or, with the depth
  cap, quietly terminate having produced a wrong subordinate set. Both fail
  silently as *authorization* bugs rather than as visible faults.

  The same guard exists for business units in
  `AshEnterprise.Accounts.Changes.MaintainBusinessUnitPath` — there it is enforced
  against the materialized path, here by walking the chain, because positions have
  no path column.
  """

  use Ash.Resource.Validation

  require Ash.Query

  # Positions are shallow in practice. This bound exists so a pre-existing cycle
  # in the data cannot make the *validation* hang.
  @max_walk 64

  @impl true
  def validate(changeset, _opts, _context) do
    id = changeset.data && Map.get(changeset.data, :id)
    parent_id = Ash.Changeset.get_attribute(changeset, :parent_position_id)

    cond do
      is_nil(parent_id) ->
        :ok

      is_nil(id) ->
        # Creating: the new row has no id yet, so it cannot be in its own chain.
        :ok

      parent_id == id ->
        invalid("a position cannot report to itself")

      true ->
        if id in ancestors(changeset, parent_id) do
          invalid("a position cannot report to one of its own subordinates")
        else
          :ok
        end
    end
  end

  # Walk upward from `start_id`, collecting every node in the chain INCLUDING
  # `start_id` and the topmost ancestor.
  #
  # Including the top matters: for `exec` being reparented under `sales`, the
  # chain above `sales` is [sales, exec], and it is `exec` -- the node with no
  # parent -- whose presence proves the cycle. Halting without collecting it
  # silently accepts exactly the cycles this validation exists to reject.
  defp ancestors(changeset, start_id) do
    Enum.reduce_while(1..@max_walk//1, {[], start_id}, fn _, {acc, current} ->
      case current && fetch_parent(changeset, current) do
        nil -> {:halt, {[current | acc], nil}}
        parent_id -> {:cont, {[current | acc], parent_id}}
      end
    end)
    |> elem(0)
    |> Enum.reject(&is_nil/1)
  end

  defp fetch_parent(changeset, position_id) do
    AshEnterprise.Accounts.Position
    |> Ash.Query.filter(id == ^position_id)
    |> Ash.Query.select([:id, :parent_position_id])
    |> Ash.read_one(authorize?: false, tenant: changeset.tenant)
    |> case do
      {:ok, %{parent_position_id: parent_id}} -> parent_id
      _ -> nil
    end
  end

  defp invalid(message) do
    {:error,
     Ash.Error.Changes.InvalidAttribute.exception(
       field: :parent_position_id,
       message: message
     )}
  end
end
