defmodule Battery.Execution.Identity do
  @moduledoc """
  The battery's `AshAgent.ExecutionIdentity`: a member asks, and the work runs as that
  member, read again at every claim.
  """

  @behaviour AshAgent.ExecutionIdentity

  alias Battery.Execution.Member

  @impl true
  def principal_for(%Member{id: id}, _context), do: {:ok, %{type: :person, id: id}}
  def principal_for(_actor, _context), do: {:error, :not_a_member}

  @impl true
  def actor_for(%{executing_principal: principal}) do
    case AshAgent.ExecutionIdentity.identity(principal) do
      {"person", id, _, _} -> Ash.get(Member, id, authorize?: false)
      _other -> {:error, :no_principal}
    end
  end
end
