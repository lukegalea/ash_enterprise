defmodule AshEnterprise.Bpmn.Subscription.Validations.StandingGrantSteps do
  @moduledoc """
  Refuses to publish a standing grant whose process names a step that cannot run as the
  intersection of its publisher and the `recipe_runner`.

  A `:standing_grant` version's steps run through their invocation, as the automation
  principal acting for the accountable person (`AshEnterprise.Process.ServiceInvocation`).
  Only an action-invoker entry that names a declared target runs that way
  (`AshEnterprise.Process.ActionInvoker.invocation_target?/1`). Every other entry is a legacy
  one that runs as the platform's process actor or as whoever started the instance, so it
  would run outside the grant; `grant_role` is one of them, and assigning a role is never a
  recipe's step. An `ash:call` binding runs as the engine's actor, so it is refused too.

  Reads the compiled graph of the latest published version of `process_key` in the tenant,
  the one the sweep would start, as the platform's process actor, the way the sweep does.
  What it cannot see (a later version under the key, a decision route choosing another, a
  call activity's child) is refused at the step instead (`AshEnterprise.Process.RecipeAuthority`).
  """

  use Ash.Resource.Validation

  alias AshEnterprise.Bpmn.Definition
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Process.ActionInvoker

  @impl true
  def validate(changeset, _opts, _context) do
    with key when is_binary(key) <- Ash.Changeset.get_attribute(changeset, :process_key),
         [_ | _] = refused <- refused_steps(key, changeset.tenant) do
      {:error,
       field: :authority,
       message:
         "a standing grant cannot start #{key}: #{Enum.join(refused, ", ")} would not run " <>
           "within the publisher's authority; only steps that name a declared target can"}
    else
      _ -> :ok
    end
  end

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
    case Definition.latest_published(key, actor: SystemActor.process(), tenant: tenant) do
      {:ok, [definition | _]} -> refused(definition.graph)
      _ -> []
    end
  end
end
