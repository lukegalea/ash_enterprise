defmodule AshEnterprise.Process.RecipeAuthority do
  @moduledoc """
  Whether a service or send task may run, given the recipe that started its process.

  A recipe (a published `AshEnterprise.Bpmn.Subscription`) starts a process because an
  event happened, and an event grants nothing. What the process's steps may do comes from
  the subscription's `authority` (`AshEnterprise.Bpmn.Subscription.Authority`). Publishing
  checks the diagram it can see; this checks again at the step, because the diagram can
  change under a published subscription (a new version of the process key, a decision
  route choosing another) and only the step knows what actually ran.

  | The process was started by | The step |
  |---|---|
  | no recipe (a person, a call from code) | runs as it always has |
  | a `:causing_person` recipe on the allowlisted key | runs as it always has |
  | a `:human_tasks_only` recipe | runs nothing: `{:no_authority, :human_tasks_only}` |
  | a `:causing_person` recipe on any other key | runs nothing: `{:no_authority, :causing_person_not_allowed}` |
  | a `:standing_grant` recipe | runs nothing: `{:no_authority, :standing_grant}`, until standing grants are built |
  | a recipe whose subscription cannot be read | runs nothing: `{:no_authority, :no_subscription}` |

  A call activity's child has no dispatch of its own, so the instance tree is walked up to
  its root, the instance a dispatch names.

  ## Claim logic, not a policy check

  Called by `AshEnterprise.Process.ActionInvoker` before it runs anything, the same seam
  every service and send task passes. It reads the dispatch and subscription rows without
  authorization, as `AshEnterprise.Execution.Identity` reads a person: deciding whether the
  step has any authority is what this is for, and nothing here is a policy check.
  """

  require Ash.Query
  require Logger

  alias AshEnterprise.Bpmn.{Dispatch, Instance, Subscription}
  alias AshEnterprise.Bpmn.Subscription.Authority
  alias AshEnterprise.Process.EngineContext

  # Call activities nest; a tree deeper than this is refused rather than walked forever.
  @max_depth 32

  @typedoc "Why a step has no authority."
  @type reason ::
          :human_tasks_only
          | :causing_person_not_allowed
          | :standing_grant
          | :no_subscription
          | :tree_too_deep

  @doc """
  `:ok` when the step the engine context `ctx` describes may run, or
  `{:error, {:no_authority, reason}}` when it must run nothing.
  """
  @spec check(map()) :: :ok | {:error, {:no_authority, reason()}}
  def check(ctx) when is_map(ctx) do
    case ctx[:instance] do
      %{id: id} = instance when is_binary(id) ->
        tenant = EngineContext.tenant(ctx) || instance_tenant(instance)

        with {:ok, root} <- root(instance, tenant, 0),
             {:ok, subscription} <- recipe(root, tenant) do
          decide(subscription, root)
        end

      _no_instance ->
        :ok
    end
  end

  defp decide(nil, _root), do: :ok

  defp decide(%Subscription{authority: :causing_person, key: key} = subscription, root) do
    if Authority.causing_person?(key),
      do: :ok,
      else: refuse(:causing_person_not_allowed, subscription, root)
  end

  defp decide(%Subscription{authority: authority} = subscription, root)
       when authority in [:human_tasks_only, :standing_grant],
       do: refuse(authority, subscription, root)

  defp decide(%Subscription{} = subscription, root),
    do: refuse(:human_tasks_only, subscription, root)

  defp refuse(reason, subscription, root) do
    Logger.warning(
      "recipe #{subscription && subscription.key} started instance #{root.id} with no " <>
        "authority for a service task (#{reason}); it runs nothing"
    )

    {:error, {:no_authority, reason}}
  end

  defp root(_instance, _tenant, depth) when depth > @max_depth,
    do: {:error, {:no_authority, :tree_too_deep}}

  defp root(%{parent_instance_id: parent_id}, tenant, depth) when is_binary(parent_id) do
    Instance
    |> Ash.Query.filter(id == ^parent_id)
    |> Ash.Query.select([:id, :parent_instance_id, :organization_id])
    |> Ash.read_one(authorize?: false, tenant: tenant)
    |> case do
      {:ok, %Instance{} = parent} -> root(parent, tenant, depth + 1)
      _missing -> {:error, {:no_authority, :no_subscription}}
    end
  end

  defp root(instance, _tenant, _depth), do: {:ok, instance}

  # The subscription that started `root`, or nil when no recipe did.
  defp recipe(root, tenant) do
    Dispatch
    |> Ash.Query.filter(
      instance_id == ^root.id and status == :started and not is_nil(subscription_id)
    )
    |> Ash.Query.select([:id, :subscription_id])
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false, tenant: tenant)
    |> case do
      {:ok, nil} -> {:ok, nil}
      {:ok, %Dispatch{subscription_id: nil}} -> {:ok, nil}
      {:ok, %Dispatch{subscription_id: id}} -> subscription(id, root, tenant)
      {:error, _error} -> refuse(:no_subscription, nil, root)
    end
  end

  defp subscription(id, root, tenant) do
    case Ash.get(Subscription, id, authorize?: false, tenant: tenant, not_found_error?: false) do
      {:ok, %Subscription{} = subscription} -> {:ok, subscription}
      _missing -> refuse(:no_subscription, nil, root)
    end
  end

  defp instance_tenant(%{organization_id: id}), do: id
  defp instance_tenant(_instance), do: nil
end
