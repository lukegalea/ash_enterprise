defmodule Battery.Execution.Identity do
  @moduledoc """
  The battery's `AshAgent.ExecutionIdentity`: a member asks, and the work runs as that
  member, read again at every claim. Any member may start an agent, and its run runs as
  them; its tool calls are asked for by them.
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

  @impl true
  def principal_of(%Member{id: id}), do: {:ok, %{type: :person, id: id}}
  def principal_of(_actor), do: :error

  @impl true
  def run_principal(%Member{id: id}, _version, _context), do: {:ok, %{type: :person, id: id}}
  def run_principal(_actor, _version, _context), do: {:error, :not_a_member}

  @impl true
  def requester_for(run), do: actor_for(run)
end
