defmodule AshEnterprise.Accounts.Preparations.DelegateCandidates do
  @moduledoc """
  Narrows a user read to the people a task may be handed to: the ones
  `AshBpmn.delegate_task/2` would accept, other than the person holding it.

  That is the engine's rule (`AshBpmn.Candidacy`), applied to every candidate
  at once: a `:user` candidate row names the person, or a `:team` row names
  one of their teams, and the task's recorded exclusions name neither them nor
  any of their teams (maker-checker). The list is offered only to the task's
  holder: the task is read **as the actor**, and a task they cannot read or do
  not hold yields nobody.

  The candidate rows and team memberships are then read as the system, in the
  task's tenant. Who may take a task is a fact about the task, and its holder
  needs no grant on users or teams to hand on their own work — a Data Steward
  holds none. Three queries, however many teams the candidates span.

  Used by `AshEnterpriseWeb.A2ui.TaskBoardUI`'s Delegate picker (a per-row
  prompt option scope), which re-reads every pick through this read before
  the engine checks it again.
  """

  use Ash.Resource.Preparation

  require Ash.Query

  alias AshEnterprise.Accounts.TeamMembership
  alias AshEnterprise.Bpmn.{HumanTask, TaskCandidate}
  alias AshEnterprise.Security.ActorContext

  @impl true
  def prepare(query, _opts, context) do
    task_id = Ash.Query.get_argument(query, :task_id)

    case held_task(task_id, context) do
      {:ok, task} ->
        Ash.Query.filter(query, id in ^delegate_ids(task, context.actor))

      :none ->
        Ash.Query.filter(query, false)

      {:error, error} ->
        Ash.Query.add_error(query, error)
    end
  end

  defp held_task(task_id, %{actor: %{id: actor_id} = actor} = context)
       when is_binary(actor_id) do
    opts = context |> Ash.Context.to_opts() |> Keyword.put(:not_found_error?, false)

    case Ash.get(HumanTask, task_id, opts) do
      {:ok, nil} ->
        :none

      {:ok, task} ->
        if AshBpmn.Candidacy.holds?(task, principals(actor_id, actor_team_ids(actor))),
          do: {:ok, task},
          else: :none

      {:error, %Ash.Error.Forbidden{}} ->
        :none

      {:error, error} ->
        {:error, error}
    end
  end

  defp held_task(_task_id, _context), do: :none

  defp actor_team_ids(actor), do: ActorContext.for_actor(actor).team_ids

  defp delegate_ids(task, actor) do
    tenant = task.organization_id

    rows =
      TaskCandidate
      |> Ash.Query.filter(task_id == ^task.id)
      |> Ash.Query.select([:principal_type, :principal_id])
      |> Ash.read!(tenant: tenant, authorize?: false)

    named = for %{principal_type: :user, principal_id: id} <- rows, do: id
    teams = for %{principal_type: :team, principal_id: id} <- rows, do: id

    members = memberships(:team_id, teams, tenant)
    candidates = Enum.uniq(named ++ Enum.map(members, & &1.user_id)) -- [actor.id]
    teams_of = candidates |> memberships_of(tenant) |> Enum.group_by(& &1.user_id, & &1.team_id)

    Enum.reject(candidates, fn id ->
      AshBpmn.Candidacy.excluded?(task, principals(id, Map.get(teams_of, id, [])))
    end)
  end

  defp memberships_of(user_ids, tenant), do: memberships(:user_id, user_ids, tenant)

  defp memberships(_key, [], _tenant), do: []

  defp memberships(:team_id, ids, tenant) do
    TeamMembership
    |> Ash.Query.filter(team_id in ^ids)
    |> Ash.Query.select([:user_id, :team_id])
    |> Ash.read!(tenant: tenant, authorize?: false)
  end

  defp memberships(:user_id, ids, tenant) do
    TeamMembership
    |> Ash.Query.filter(user_id in ^ids)
    |> Ash.Query.select([:user_id, :team_id])
    |> Ash.read!(tenant: tenant, authorize?: false)
  end

  defp principals(user_id, team_ids), do: %{user_id: user_id, team_ids: team_ids}
end
