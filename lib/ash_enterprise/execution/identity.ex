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

  ## An agent run

  A run (`AshEnterprise.Execution.Run`) is started by a person who holds the agent's
  start grant (`run_principal/3`), and executes as its version's publish-time authority:
  that person, or the automation principal the publisher named acting for them. Every
  step rebuilds the run's actor with `actor_for/1`, exactly as a claim does; every tool
  call it makes is requested as the person (`requester_for/1`) and so executes as the run
  does.

  Whichever authority it executes as, a run is held to the agent's start grant after it
  starts: every step, every tool call it requests and every claim of one is refused as
  `:denied` once the person no longer holds the grant. An automation principal names its
  agent; for a run executing as its requester the agent is read from the run (its
  `agent_key`, or that of the run a tool call belongs to).

  ## Not a principal

  System actors are not principals: the job runner claims and completes invocations but
  never runs a target as itself, and the `ai` attribution label has no authority of its
  own (ADR 0043). Nor is an automation principal itself a requester: it runs work, it
  does not ask for it.
  """

  @behaviour AshAgent.ExecutionIdentity

  require Ash.Query

  alias AshEnterprise.Accounts.{BusinessUnit, User}
  alias AshEnterprise.Execution.{Invocation, Run}
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
  def actor_for(%{executing_principal: principal, organization_id: tenant} = row) do
    case AshAgent.ExecutionIdentity.identity(principal) do
      {"person", id, _, _} -> with {:ok, agent} <- agent_of(row), do: person(id, tenant, agent)
      {"automation", name, person_id, agent} -> automation_actor(name, person_id, agent, tenant)
      _other -> {:error, :no_principal}
    end
  end

  def actor_for(_invocation), do: {:error, :no_principal}

  @doc """
  The principal an actor `actor_for/1` built runs as: a person, or an automation
  principal acting for one. Read from the actor alone. A user asking to start an agent
  (`AutomationPrincipal.requested/1`) is not an actor `actor_for/1` builds, nor is any
  system actor.
  """
  @impl true
  def principal_of(%User{id: id} = user) when is_binary(id) do
    case AutomationPrincipal.requested(user) do
      nil -> {:ok, %{type: :person, id: id}}
      _starting_an_agent -> :error
    end
  end

  def principal_of(%AutomationPrincipal{name: name, id: person_id, agent: agent})
      when is_atom(name) and is_binary(person_id),
      do:
        {:ok,
         %{type: :automation, id: Atom.to_string(name), on_behalf_of: person_id, agent: agent}}

  def principal_of(_actor), do: :error

  @doc """
  Who a run of `version` started by `actor` executes as (`AshEnterprise.Execution.Run`).
  Only a person in the run's tenant who holds the agent's start grant may start it; the
  run then executes as them, or, when the version was published with an automation
  authority, as that principal acting for them. Read at the start, and rebuilt at every
  step by `actor_for/1` like any principal.
  """
  @impl true
  def run_principal(%User{id: id} = user, version, context) when is_binary(id) do
    with :ok <- may_start(user, version.key, context[:tenant]) do
      run_as(version.authority, id, version.key)
    end
  end

  def run_principal(_actor, _version, _context), do: {:error, :not_a_person}

  defp run_as(%{type: :automation, name: name}, person_id, agent) do
    with {:ok, principal} <- principal(name) do
      {:ok,
       %{
         type: :automation,
         id: Atom.to_string(principal.name),
         on_behalf_of: person_id,
         agent: agent
       }}
    end
  end

  defp run_as(_requester, person_id, _agent), do: {:ok, %{type: :person, id: person_id}}

  @doc """
  The actor a run's tool calls are requested as: the person who started it, rebuilt
  from their grants now, and marked to run as the run's automation principal when it has
  one (`AutomationPrincipal.start/3`), so `principal_for/2` names exactly the run's
  principal. A person who has lost their authority since cannot ask for more.
  """
  @impl true
  def requester_for(%{executing_principal: principal, organization_id: tenant} = run) do
    case AshAgent.ExecutionIdentity.identity(principal) do
      {"person", id, _, _} ->
        person(id, tenant, run.agent_key)

      {"automation", name, person_id, agent} when is_binary(person_id) ->
        with {:ok, principal} <- principal(name),
             {:ok, actor} <- person(person_id, tenant) do
          {:ok, AutomationPrincipal.start(actor, principal.name, agent)}
        end

      _other ->
        {:error, :requesterless}
    end
  end

  @doc """
  The person `id` as an actor in `tenant`, their `ActorContext` built from their grant
  rows now: the actor a process's service task requests a declared target as, when that
  person started the instance (`AshEnterprise.Process.ServiceInvocation`). Refused, like
  a claim, for a person who no longer exists, is no longer active, or belongs to another
  tenant.
  """
  @spec person_actor(Ash.UUID.t(), Ash.UUID.t()) :: {:ok, User.t()} | {:error, term()}
  def person_actor(id, tenant), do: person(id, tenant)

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

  # A person running an agent does so only while they hold its start grant.
  defp person(id, tenant, nil), do: person(id, tenant)

  defp person(id, tenant, agent) do
    with {:ok, user} <- member(id, tenant),
         :ok <- may_start(user, agent, tenant) do
      {:ok, ActorContext.attach(user, ActorContext.build(user, tenant: tenant))}
    end
  end

  # The agent a person's work runs for: a run's own, the run's that a tool call belongs
  # to, or none for an invocation a person asked for directly.
  defp agent_of(%Run{agent_key: agent}), do: {:ok, agent}
  defp agent_of(%Invocation{run_id: nil}), do: {:ok, nil}

  defp agent_of(%Invocation{run_id: run_id, organization_id: tenant}) do
    Run
    |> Ash.Query.filter(id == ^run_id)
    |> Ash.Query.select([:agent_key])
    |> Ash.read_one(authorize?: false, tenant: tenant)
    |> case do
      {:ok, %Run{agent_key: agent}} -> {:ok, agent}
      {:ok, nil} -> {:error, :no_such_run}
      {:error, error} -> {:error, error}
    end
  end

  defp agent_of(_row), do: {:ok, nil}

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
  defp may_start(_user, _agent, nil), do: {:error, :no_tenant}

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
