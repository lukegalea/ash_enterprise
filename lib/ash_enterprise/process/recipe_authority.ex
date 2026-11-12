defmodule AshEnterprise.Process.RecipeAuthority do
  @moduledoc """
  Whether a service or send task may run, and as whom, given the recipe that started its
  process.

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
  | a `:standing_grant` recipe whose publisher is an active member holding the version's grant | runs as the `recipe_runner` acting for the publisher: `{:ok, %{authority: :standing_grant, ...}}` |
  | a `:standing_grant` recipe whose publisher has left, is inactive or no longer holds the grant | runs nothing: `{:no_authority, reason}`, the reason `AshEnterprise.Execution.Identity` gives |
  | a `:standing_grant` recipe, in an instance whose definition (or an ancestor's) its publisher did not see | runs nothing: `{:no_authority, :definition_not_granted}` |
  | a recipe whose subscription cannot be read | runs nothing: `{:no_authority, :no_subscription}` |

  A call activity's child has no dispatch of its own, so the instance tree is walked up to
  its root, the instance a dispatch names; a child of a standing-grant recipe's process runs
  under the same grant.

  ## A standing grant

  The step runs as the `recipe_runner` automation principal acting for the person stamped
  as the version's `accountable_person_id`, for the version's start grant
  (`Authority.grant_key/1`), never for whoever caused the event (ADR 0069). That person is
  rebuilt here, at every step, and again when the step's invocation is claimed, so a
  deactivated or departed publisher, or a grant revoked or past its `valid_until`, stops the
  step before it runs. The tenant is the instance's, never the job's arguments: a mismatch
  runs nothing.

  The grant covers the diagrams its publisher saw and no others: the step's instance and
  every ancestor up to the root must run a definition in the version's
  `granted_definition_ids`, stamped by `publish_granted`. A later version under the key, or
  a call activity's child published since, runs nothing until a person publishes the recipe
  again.

  ## Rows only the engine writes

  The dispatch and the instance tree this reads are `engine_only` to create
  (`AshEnterprise.Bpmn.Dispatch`, `AshEnterprise.Bpmn.Instance`): no role grant and no system
  actor writes one, so a person cannot attach a publisher's recipe to an instance they
  started, or start an instance under a recipe's.

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
  alias AshEnterprise.Execution.Identity
  alias AshEnterprise.Platform.AutomationPrincipal
  alias AshEnterprise.Process.EngineContext
  alias AshEnterprise.Security.AgentStartGrant

  # Call activities nest; a tree deeper than this is refused rather than walked forever.
  @max_depth 32

  @typedoc "Why a step has no authority."
  @type reason ::
          :human_tasks_only
          | :causing_person_not_allowed
          | :no_subscription
          | :tree_too_deep
          | :no_tenant
          | :other_tenant
          | term()

  @typedoc "What a step of a standing-grant recipe's process runs under."
  @type standing_grant :: %{
          authority: :standing_grant,
          requester: struct(),
          tenant: Ash.UUID.t(),
          subscription_id: Ash.UUID.t(),
          dispatch_id: Ash.UUID.t()
        }

  @doc """
  `:ok` when the step the engine context `ctx` describes runs as it always has,
  `{:ok, standing_grant}` when it runs under a standing grant, or
  `{:error, {:no_authority, reason}}` when it must run nothing.
  """
  @spec check(map()) :: :ok | {:ok, standing_grant()} | {:error, {:no_authority, reason()}}
  def check(ctx) when is_map(ctx) do
    case ctx[:instance] do
      %{id: id} = instance when is_binary(id) ->
        # The instance knows its tenant; the job's arguments only say where to look.
        tenant = instance_tenant(instance) || EngineContext.tenant(ctx)

        with {:ok, chain} <- chain(instance, tenant, 0, []),
             root = List.last(chain),
             {:ok, recipe} <- recipe(root, tenant) do
          decide(recipe, root, Map.put(ctx, :chain, chain))
        end

      _no_instance ->
        :ok
    end
  end

  @doc """
  What a recipe runner's claimed actor ran under, for the audit entry: the dispatch that
  started the invocation's process tree, the event it answered and the start grant
  `person_id` holds for `grant_key`. Provenance, never authority; a value that cannot be
  read is nil.
  """
  @spec provenance(map(), Ash.UUID.t() | nil, String.t() | nil, Ash.UUID.t() | nil) :: %{
          dispatch_id: Ash.UUID.t() | nil,
          event_id: Ash.UUID.t() | nil,
          grant_id: Ash.UUID.t() | nil
        }
  def provenance(row, person_id, grant_key, tenant) do
    dispatch =
      with %{process_instance_id: id} when is_binary(id) <- row,
           {:ok, %Instance{} = instance} <- read_instance(id, tenant),
           {:ok, root} <- root(instance, tenant, 0),
           {:ok, {_subscription, dispatch}} <- recipe(root, tenant) do
        dispatch
      else
        _none -> nil
      end

    %{
      dispatch_id: dispatch && dispatch.id,
      event_id: dispatch && dispatch.event_id,
      grant_id: grant_id(person_id, grant_key, tenant)
    }
  end

  @doc """
  Whether `actor` asks for work in the process instance `instance_id` as that tree's
  standing grant: it is the person the root's recipe version names as accountable, marked
  to run as the `recipe_runner` for that version's grant. Lets a recipe runner's request
  name the instance as its parent although the person did not start it
  (`AshEnterprise.Execution.Validations.OwnsParent`).
  """
  @spec runs_for?(Ash.UUID.t(), Ash.UUID.t() | nil, term()) :: boolean()
  def runs_for?(instance_id, tenant, %{id: person_id} = actor) when is_binary(person_id) do
    with %{name: :recipe_runner, agent: grant_key} <- AutomationPrincipal.requested(actor),
         {:ok, %Instance{} = instance} <- read_instance(instance_id, tenant),
         {:ok, root} <- root(instance, tenant, 0),
         {:ok, {%Subscription{authority: :standing_grant} = subscription, _}} <-
           recipe(root, tenant) do
      subscription.accountable_person_id == person_id and
        Authority.grant_key(subscription) == grant_key
    else
      _ -> false
    end
  end

  def runs_for?(_instance_id, _tenant, _actor), do: false

  defp decide(nil, _root, _ctx), do: :ok

  defp decide({%Subscription{authority: :causing_person, key: key} = subscription, _}, root, _) do
    if Authority.causing_person?(key),
      do: :ok,
      else: refuse(:causing_person_not_allowed, subscription, root)
  end

  defp decide({%Subscription{authority: :standing_grant} = subscription, dispatch}, root, ctx),
    do: standing_grant(subscription, dispatch, root, ctx)

  defp decide({%Subscription{} = subscription, _dispatch}, root, _ctx),
    do: refuse(:human_tasks_only, subscription, root)

  # The tenant is the instance's own. A job that names another runs nothing.
  defp standing_grant(subscription, dispatch, root, ctx) do
    tenant = instance_tenant(root)

    cond do
      is_nil(tenant) ->
        refuse(:no_tenant, subscription, root)

      ctx[:tenant] not in [nil, tenant] ->
        refuse(:other_tenant, subscription, root)

      true ->
        subscription.accountable_person_id
        |> Identity.recipe_requester(Authority.grant_key(subscription), tenant)
        |> case do
          {:ok, requester} ->
            granted(subscription, dispatch, root, ctx, requester, tenant)

          {:error, reason} ->
            refuse(reason, subscription, root)
        end
    end
  end

  # Every instance from the step's up to the root runs a definition the publisher saw.
  defp granted(subscription, dispatch, root, ctx, requester, tenant) do
    granted_ids = subscription.granted_definition_ids || []

    if Enum.all?(Map.get(ctx, :chain, [root]), &(&1.definition_id in granted_ids)) do
      {:ok,
       %{
         authority: :standing_grant,
         requester: requester,
         tenant: tenant,
         subscription_id: subscription.id,
         dispatch_id: dispatch.id
       }}
    else
      refuse(:definition_not_granted, subscription, root)
    end
  end

  defp refuse(reason, subscription, root) do
    Logger.warning(
      "recipe #{subscription && subscription.key} started instance #{root.id} with no " <>
        "authority for a service task (#{inspect(reason)}); it runs nothing"
    )

    {:error, {:no_authority, reason}}
  end

  defp root(instance, tenant, depth) do
    with {:ok, chain} <- chain(instance, tenant, depth, []), do: {:ok, List.last(chain)}
  end

  # The instance and its ancestors, the instance first and the root last.
  defp chain(_instance, _tenant, depth, _acc) when depth > @max_depth,
    do: {:error, {:no_authority, :tree_too_deep}}

  defp chain(%{parent_instance_id: parent_id} = instance, tenant, depth, acc)
       when is_binary(parent_id) do
    case read_instance(parent_id, tenant) do
      {:ok, %Instance{} = parent} -> chain(parent, tenant, depth + 1, [instance | acc])
      _missing -> {:error, {:no_authority, :no_subscription}}
    end
  end

  defp chain(instance, _tenant, _depth, acc), do: {:ok, Enum.reverse([instance | acc])}

  defp read_instance(id, tenant) do
    Instance
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.select([:id, :parent_instance_id, :organization_id, :definition_id])
    |> Ash.read_one(authorize?: false, tenant: tenant)
  end

  # The subscription that started `root` and the dispatch that records it, or nil when no
  # recipe did.
  defp recipe(root, tenant) do
    Dispatch
    |> Ash.Query.filter(
      instance_id == ^root.id and status == :started and not is_nil(subscription_id)
    )
    |> Ash.Query.select([:id, :subscription_id, :event_id])
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false, tenant: tenant)
    |> case do
      {:ok, nil} -> {:ok, nil}
      {:ok, %Dispatch{subscription_id: nil}} -> {:ok, nil}
      {:ok, %Dispatch{subscription_id: id} = dispatch} -> subscription(id, dispatch, root, tenant)
      {:error, _error} -> refuse(:no_subscription, nil, root)
    end
  end

  defp subscription(id, dispatch, root, tenant) do
    case Ash.get(Subscription, id, authorize?: false, tenant: tenant, not_found_error?: false) do
      {:ok, %Subscription{} = subscription} -> {:ok, {subscription, dispatch}}
      _missing -> refuse(:no_subscription, nil, root)
    end
  end

  defp grant_id(person_id, grant_key, tenant)
       when is_binary(person_id) and is_binary(grant_key) and is_binary(tenant) do
    AgentStartGrant
    |> Ash.Query.filter(agent_key == ^grant_key and principal_id == ^person_id)
    |> Ash.Query.select([:id])
    |> Ash.read_one(authorize?: false, tenant: tenant)
    |> case do
      {:ok, %AgentStartGrant{id: id}} -> id
      _none -> nil
    end
  end

  defp grant_id(_person_id, _grant_key, _tenant), do: nil

  defp instance_tenant(%{organization_id: id}), do: id
  defp instance_tenant(_instance), do: nil
end
