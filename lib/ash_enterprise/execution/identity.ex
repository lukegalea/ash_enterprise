defmodule AshEnterprise.Execution.Identity do
  @moduledoc """
  Who an invocation runs as (`AshAgent.ExecutionIdentity`, ADR 0055 "Identity at
  execution", ADR 0043).

  Authority is rebuilt from grant rows at every claim, never carried over from the
  request. Rebuilding is claim logic, so it reads what it needs; no policy check does.

  ## A person

  A request made by a person executes as that person: the principal is
  `%{type: :person, id: user_id}`. At every claim the person is read again and their
  `ActorContext` rebuilt from the grant rows as they are then, in the invocation's
  tenant, so a revoked role or a deactivated account takes effect before the work
  runs, never after. A person who no longer exists, is no longer active, or no longer
  belongs to the invocation's tenant (their business unit is another organization's)
  has no authority, and the invocation fails as `:denied` without running its target.

  ## An automation principal

  A person asks for work to run as an automation principal
  (`AshEnterprise.Platform.AutomationPrincipal.start/3`) for an agent. The request
  refuses unless they hold that agent's start grant
  (`AshEnterprise.Security.AgentStartGrant`), and names the principal
  `%{type: :automation, id: name, on_behalf_of: user_id, agent: agent_key}`.

  At every claim the person is rebuilt as above, the start grant is read again, the
  principal's own context is built from its role rows
  (`AshEnterprise.Security.ActorContext.build_automation/2`), and the work runs on the
  intersection of the two (`AshEnterprise.Security.ActorContext.intersect/2`), as the
  principal acting for the person. Revoking the person's role or the principal's
  narrows the intersection, so the target is refused; revoking the start grant, or
  the person losing their account or tenant, fails the row before the target is
  tried. Each refusal is `:denied`, and the target never runs.

  Work no person asked for runs only for agent versions published as requesterless,
  which do not exist yet: a principal with no person is refused at the request and at
  the claim.

  ## Not a principal

  System actors are not principals: the job runner claims and completes invocations but
  never runs a target as itself, and the `ai` attribution label has no authority of its
  own (ADR 0043). Nor is an automation principal itself a requester: it runs work, it
  does not ask for it.
  """

  @behaviour AshAgent.ExecutionIdentity

  require Ash.Query

  alias AshEnterprise.Accounts.{BusinessUnit, User}
  alias AshEnterprise.Platform.AutomationPrincipal
  alias AshEnterprise.Security.{ActorContext, AgentStartGrant}

  @impl true
  def principal_for(%User{id: id} = user, context) when is_binary(id) do
    case AutomationPrincipal.requested(user) do
      nil -> {:ok, %{type: :person, id: id}}
      %{name: name, agent: agent} -> automation(user, name, agent, context[:tenant])
    end
  end

  def principal_for(_actor, _context), do: {:error, :not_a_person}

  @impl true
  def actor_for(%{executing_principal: principal, organization_id: tenant}) do
    case AshAgent.ExecutionIdentity.identity(principal) do
      {"person", id, _, _} -> person(id, tenant)
      {"automation", name, person_id, agent} -> automation_actor(name, person_id, agent, tenant)
      _other -> {:error, :no_principal}
    end
  end

  def actor_for(_invocation), do: {:error, :no_principal}

  # --- request --------------------------------------------------------------

  defp automation(_user, _name, _agent, nil), do: {:error, :no_tenant}

  defp automation(user, name, agent, tenant) do
    with {:ok, principal} <- principal(name),
         :ok <- may_start(user, agent, tenant) do
      {:ok,
       %{
         type: :automation,
         id: Atom.to_string(principal.name),
         on_behalf_of: user.id,
         agent: agent
       }}
    end
  end

  # --- claim ----------------------------------------------------------------

  defp person(id, tenant) do
    with {:ok, user} <- member(id, tenant) do
      {:ok, ActorContext.attach(user, ActorContext.build(user, tenant: tenant))}
    end
  end

  defp automation_actor(_name, nil, _agent, _tenant), do: {:error, :requesterless}

  defp automation_actor(name, person_id, agent, tenant) do
    with {:ok, principal} <- principal(name),
         {:ok, user} <- member(person_id, tenant),
         :ok <- may_start(user, agent, tenant) do
      context =
        ActorContext.intersect(
          ActorContext.build(user, tenant: tenant),
          ActorContext.build_automation(principal.name, tenant)
        )

      {:ok, AutomationPrincipal.acting(principal, user.id, agent, context)}
    end
  end

  # Read without authorization: rebuilding an identity is claim logic, not a policy
  # check, and what the person may do is decided by the context built from it.
  defp member(id, tenant) do
    case Ash.get(User, id, authorize?: false, not_found_error?: false) do
      {:ok, %User{lifecycle_status: :active} = user} ->
        if home_tenant(user) == tenant, do: {:ok, user}, else: {:error, :other_tenant}

      {:ok, %User{}} ->
        {:error, :inactive}

      {:ok, nil} ->
        {:error, :no_such_person}

      {:error, error} ->
        {:error, error}
    end
  end

  # A user carries no tenant; their business unit's organization is theirs. A row in a
  # tenant the person does not belong to is never run as them, whatever role rows that
  # tenant still holds for their id.
  defp home_tenant(%User{owning_business_unit_id: nil}), do: nil

  defp home_tenant(%User{owning_business_unit_id: unit_id}) do
    case Ash.get(BusinessUnit, unit_id, authorize?: false, not_found_error?: false) do
      {:ok, %{organization_id: organization_id}} -> organization_id
      _missing -> nil
    end
  end

  defp principal(name) do
    case AutomationPrincipal.fetch(name) do
      {:ok, principal} -> {:ok, principal}
      :error -> {:error, :unknown_automation_principal}
    end
  end

  defp may_start(_user, agent, _tenant) when not is_binary(agent), do: {:error, :no_agent}

  defp may_start(user, agent, tenant) do
    principal_ids = [user.id | ActorContext.team_ids_for(user.id, tenant)]

    AgentStartGrant
    |> Ash.Query.filter(agent_key == ^agent and principal_id in ^principal_ids)
    |> Ash.exists(authorize?: false, tenant: tenant)
    |> case do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :no_start_grant}
      {:error, error} -> {:error, error}
    end
  end
end
