defmodule AshEnterprise.Bpmn.Subscription.Validations.StandingGrantSteps do
  @moduledoc """
  Refuses to publish a standing grant whose process names a step that cannot run as the
  intersection of its publisher and the `recipe_runner`, or whose process is not named.

  A `:standing_grant` version's steps run through their invocation, as the automation
  principal acting for the accountable person (`AshEnterprise.Process.ServiceInvocation`).
  Only an action-invoker entry that names a declared target runs that way
  (`AshEnterprise.Process.ActionInvoker.invocation_target?/1`). Every other entry is a legacy
  one that runs as the platform's process actor or as whoever started the instance, so it
  would run outside the grant; `grant_role` is one of them, and assigning a role is never a
  recipe's step. An `ash:call` binding runs as the engine's actor, so it is refused too.

  ## What the publisher saw

  Reads the compiled graph of the latest published version of `process_key` in the tenant,
  the one the sweep would start, as the platform's process actor, the way the sweep does,
  and of every call activity's child, the version it names or the latest published one.
  Those are the diagrams the publisher reviewed, and `definitions/2` is what
  `publish_granted` stamps as the version's `granted_definition_ids`. A step of any other
  definition (a later version under the key, a child published later) runs nothing
  (`AshEnterprise.Process.RecipeAuthority`, `:definition_not_granted`) until a person
  publishes the recipe again.

  A decision route chooses its process when the event arrives, so there is no diagram to
  see: a standing grant names one process (`route_kind: :static`), and a decision route is
  refused.
  """

  use Ash.Resource.Validation

  alias AshEnterprise.Bpmn.Definition
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Process.ActionInvoker

  # Call activities nest; a deeper tree is refused at the step anyway.
  @max_depth 32

  @named_process "a standing grant starts one named process: give it a process_key, not a " <>
                   "decision route, so its publisher sees the diagram it runs"

  @impl true
  def validate(changeset, _opts, _context) do
    route_kind = Ash.Changeset.get_attribute(changeset, :route_kind)
    key = Ash.Changeset.get_attribute(changeset, :process_key)

    if route_kind == :decision or not is_binary(key),
      do: {:error, field: :route_kind, message: @named_process},
      else: steps(key, changeset.tenant)
  end

  defp steps(key, tenant) do
    case refused_steps(key, tenant) do
      [] ->
        :ok

      refused ->
        {:error,
         field: :authority,
         message:
           "a standing grant cannot start #{key}: #{Enum.join(refused, ", ")} would not " <>
             "run within the publisher's authority; only steps that name a declared " <>
             "target can"}
    end
  end

  @doc """
  The published definitions a standing grant on `process_key` covers in `tenant`: the latest
  published version of the key and, through every call activity, the child it would start
  now. Each appears once, root first.
  """
  @spec definitions(String.t() | nil, Ash.UUID.t() | nil) :: [struct()]
  def definitions(key, tenant) when is_binary(key) do
    case latest(key, tenant) do
      nil -> []
      root -> walk([root], tenant, [], MapSet.new(), 0)
    end
  end

  def definitions(_key, _tenant), do: []

  @doc """
  The steps of a compiled graph that could not run under a standing grant, described for a
  person, sorted by node id.
  """
  @spec refused(map() | nil) :: [String.t()]
  def refused(%{"nodes" => nodes}) when is_map(nodes) do
    nodes
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {id, node} -> refusal(id, node) end)
  end

  def refused(_graph), do: []

  defp refusal(id, %{"call" => %{"ref" => ref}} = node),
    do: ["#{node["type"]} #{id} (ash:call #{ref})"]

  defp refusal(id, %{"type" => type, "action" => action}) when is_binary(action) do
    if ActionInvoker.invocation_target?(action),
      do: [],
      else: ["#{type} #{id} (#{action}, which does not run through an invocation)"]
  end

  defp refusal(_id, _node), do: []

  defp refused_steps(key, tenant) do
    key
    |> definitions(tenant)
    |> Enum.flat_map(&refused(&1.graph))
  end

  defp walk([], _tenant, acc, _seen, _depth), do: Enum.reverse(acc)
  defp walk(_pending, _tenant, acc, _seen, depth) when depth > @max_depth, do: Enum.reverse(acc)

  defp walk([definition | rest], tenant, acc, seen, depth) do
    if MapSet.member?(seen, definition.id) do
      walk(rest, tenant, acc, seen, depth)
    else
      children = Enum.flat_map(calls(definition.graph), &child(&1, tenant))

      walk(
        rest ++ children,
        tenant,
        [definition | acc],
        MapSet.put(seen, definition.id),
        depth + 1
      )
    end
  end

  defp calls(%{"nodes" => nodes}) when is_map(nodes) do
    for {_id, %{"call_process" => %{"key" => key} = call}} <- nodes,
        is_binary(key),
        do: {key, call["version"]}
  end

  defp calls(_graph), do: []

  defp child({key, nil}, tenant), do: List.wrap(latest(key, tenant))

  defp child({key, version}, tenant) do
    case Definition.by_key_version(key, version, actor: SystemActor.process(), tenant: tenant) do
      {:ok, %Definition{} = definition} -> [definition]
      _missing -> []
    end
  end

  defp latest(key, tenant) do
    case Definition.latest_published(key, actor: SystemActor.process(), tenant: tenant) do
      {:ok, [definition | _]} -> definition
      _none -> nil
    end
  end
end
