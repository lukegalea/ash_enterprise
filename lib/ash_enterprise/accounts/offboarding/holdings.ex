defmodule AshEnterprise.Accounts.Offboarding.Holdings do
  @moduledoc """
  What a leaver holds in one organization, for the person who reviews their offboarding.

  Counts, never rows: the review needs to know what to hand over, and a count by kind says
  that without copying another resource's data into this one.

  | Key | What |
  |---|---|
  | `owned_records` | records the leaver owns (`owner_id`), by resource, only those with any |
  | `open_tasks` | human tasks assigned to them and not finished |
  | `running_processes` | process instances they started that are still running |
  | `recipes_accountable` | published recipes whose standing grant they hold (the keys) |
  | `start_grants` | start grants held by them |
  | `role_assignments` | roles assigned to them directly |
  | `team_memberships` | teams they belong to |
  | `inert_because` | why what stays cannot act while the account is inactive |

  Recipes they published stop at their next step once they are inactive (`:no_authority`,
  ADR 0069); a person hands one over by publishing it again.

  Read as the platform, within this organization only: the review must see everything the
  leaver holds here, including rows its reviewer could not read, and it sees counts.
  """

  require Ash.Query

  alias AshEnterprise.Accounts.TeamMembership
  alias AshEnterprise.Bpmn.{HumanTask, Instance, Subscription}
  alias AshEnterprise.Security.{AgentStartGrant, UserRole}

  @inert_because "The account is inactive: sign-in, a bearer key, a step's person actor and " <>
                   "a standing grant all refuse an inactive person. Ending an assignment " <>
                   "changes authority, which no automation principal does: a person ends " <>
                   "what should not come back if the account is reactivated."

  @doc "Why the assignments an offboarding leaves in place cannot act."
  @spec inert_because() :: String.t()
  def inert_because, do: @inert_because

  @doc "What `user_id` holds in the organization `tenant`. See the moduledoc."
  @spec of(Ash.UUID.t(), Ash.UUID.t()) :: map()
  def of(user_id, tenant) when is_binary(user_id) and is_binary(tenant) do
    %{
      "owned_records" => owned_records(user_id, tenant),
      "open_tasks" =>
        count(
          HumanTask
          |> Ash.Query.filter(assignee_id == ^user_id and status in [:open, :claimed]),
          tenant
        ),
      "running_processes" =>
        count(
          Instance |> Ash.Query.filter(started_by_id == ^user_id and status == :running),
          tenant
        ),
      "recipes_accountable" => recipes_accountable(user_id, tenant),
      "start_grants" =>
        count(
          AgentStartGrant
          |> Ash.Query.filter(principal_type == :user and principal_id == ^user_id),
          tenant
        ),
      "role_assignments" => count(UserRole |> Ash.Query.filter(user_id == ^user_id), tenant),
      "team_memberships" =>
        count(TeamMembership |> Ash.Query.filter(user_id == ^user_id), tenant),
      "inert_because" => @inert_because
    }
  end

  # Every tenant-scoped resource with an owner, counted for this owner; only those with any.
  defp owned_records(user_id, tenant) do
    owned_resources()
    |> Enum.flat_map(fn resource ->
      case resource |> Ash.Query.filter(owner_id == ^user_id) |> Ash.count(opts(tenant)) do
        {:ok, n} when n > 0 -> [{inspect(resource), n}]
        _none_or_unreadable -> []
      end
    end)
    |> Map.new()
  end

  @doc false
  @spec owned_resources() :: [Ash.Resource.t()]
  def owned_resources do
    :ash_enterprise
    |> Application.get_env(:ash_domains, [])
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.uniq()
    |> Enum.filter(fn resource ->
      Ash.DataLayer.data_layer(resource) == AshPostgres.DataLayer and
        Ash.Resource.Info.multitenancy_strategy(resource) == :attribute and
        not is_nil(Ash.Resource.Info.attribute(resource, :owner_id))
    end)
    |> Enum.sort_by(&inspect/1)
  end

  defp recipes_accountable(user_id, tenant) do
    Subscription
    |> Ash.Query.filter(accountable_person_id == ^user_id and status == :published)
    |> Ash.Query.select([:key, :version])
    |> Ash.read(opts(tenant))
    |> case do
      {:ok, rows} -> rows |> Enum.map(&"#{&1.key}:#{&1.version}") |> Enum.sort()
      {:error, error} -> raise error
    end
  end

  defp count(query, tenant) do
    case Ash.count(query, opts(tenant)) do
      {:ok, n} -> n
      {:error, error} -> raise error
    end
  end

  defp opts(tenant), do: [authorize?: false, tenant: tenant]
end
