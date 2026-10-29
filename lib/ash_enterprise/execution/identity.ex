defmodule AshEnterprise.Execution.Identity do
  @moduledoc """
  Who an invocation runs as (`AshAgent.ExecutionIdentity`, ADR 0055 "Identity at
  execution").

  ## A person

  A request made by a person executes as that person: the principal is
  `%{type: :person, id: user_id}`. At every claim the person is read again and their
  `ActorContext` rebuilt from the grant rows as they are then
  (`AshEnterprise.Security.ActorContext.build/2`, in the invocation's tenant), so a
  revoked role or a deactivated account takes effect before the work runs, never after.
  A person who no longer exists or is no longer active has no authority, and the
  invocation fails as `:denied` without running its target.

  ## Not a person

  System actors are not principals: the job runner claims and completes invocations but
  never runs a target as itself, and the `ai` attribution label has no authority of its
  own (ADR 0043). Automation principals, which hold grants of their own and run on the
  intersection with their requester's, are not built yet: an invocation whose principal
  is one is refused here rather than run with some other authority.
  """

  @behaviour AshAgent.ExecutionIdentity

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Security.ActorContext

  @impl true
  def principal_for(%User{id: id}, _context) when is_binary(id),
    do: {:ok, %{type: :person, id: id}}

  def principal_for(_actor, _context), do: {:error, :not_a_person}

  @impl true
  def actor_for(%{executing_principal: principal, organization_id: tenant}) do
    case principal_type(principal) do
      {"person", id} -> person(id, tenant)
      {"automation", _name} -> {:error, :automation_principals_not_built}
      _other -> {:error, :no_principal}
    end
  end

  def actor_for(_invocation), do: {:error, :no_principal}

  defp person(id, tenant) do
    # Read without authorization: rebuilding an identity is claim logic, not a policy
    # check, and what the person may do is decided by the context built below.
    case Ash.get(User, id, authorize?: false, not_found_error?: false) do
      {:ok, %User{lifecycle_status: :active} = user} ->
        {:ok, ActorContext.attach(user, ActorContext.build(user, tenant: tenant))}

      {:ok, %User{}} ->
        {:error, :inactive}

      {:ok, nil} ->
        {:error, :no_such_person}

      {:error, error} ->
        {:error, error}
    end
  end

  defp principal_type(%{} = principal) do
    {to_string(Map.get(principal, :type) || Map.get(principal, "type")),
     Map.get(principal, :id) || Map.get(principal, "id")}
  end

  defp principal_type(_principal), do: nil
end
