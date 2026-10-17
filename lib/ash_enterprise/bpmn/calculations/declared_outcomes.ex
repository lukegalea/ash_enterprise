defmodule AshEnterprise.Bpmn.Calculations.DeclaredOutcomes do
  @moduledoc """
  `HumanTask.declared_outcomes`: the outcomes the task's BPMN step declares
  (`<ash:outcomes>`), read from the definition its instance pinned — wherever
  that definition lives.

  The engine's own `:outcomes` calculation reads the definition in the task's
  tenant, so for a task running a **platform baseline** (the definition is the
  platform organization's, the instance the tenant's) it answers `nil`. This
  one loads each pinned definition through the configured definition loader
  (`AshEnterprise.Process.DefinitionLoader`, the same seam the engine uses to
  advance the instance), so a baseline's outcomes are found too.

  Instances and definitions are read with the engine's authority, once per
  distinct instance and definition in the batch: the graph is the engine's
  own data, and a person who may read a task need not be able to read process
  definitions. `nil` for a standalone approval (no instance) or a step that
  declares none — and, for display, for a task whose definition could not be
  loaded. `resolve/1` keeps that last case apart, for the checks that must
  not mistake "could not tell" for "declares none".
  """

  use Ash.Resource.Calculation

  require Ash.Query

  alias AshBpmn.Scope

  @impl true
  def load(_query, _opts, _context), do: [:instance_id, :node_id, :organization_id]

  @impl true
  def calculate(tasks, _opts, _context) do
    tasks
    |> resolve()
    |> Enum.map(fn
      {:ok, outcomes} -> outcomes
      {:error, :unresolved} -> nil
    end)
  end

  @doc """
  Per task, in order: `{:ok, outcomes}` for a step that declares some,
  `{:ok, nil}` for a standalone approval (no instance) or a step that
  declares none, and `{:error, :unresolved}` when the task belongs to an
  instance whose definition, or whose step in it, could not be read. Each
  task needs `:instance_id`, `:node_id` and `:organization_id`.
  """
  @spec resolve([struct()]) :: [{:ok, [String.t()] | nil} | {:error, :unresolved}]
  def resolve(tasks) do
    graphs = graphs(tasks)

    Enum.map(tasks, fn
      %{instance_id: nil} ->
        {:ok, nil}

      task ->
        case graphs |> Map.get(task.instance_id) |> step(task.node_id) do
          {:ok, %{"outcomes" => [_ | _] = outcomes}} -> {:ok, outcomes}
          {:ok, _declares_none} -> {:ok, nil}
          :error -> {:error, :unresolved}
        end
    end)
  end

  defp step(%{"nodes" => %{} = nodes}, node_id), do: Map.fetch(nodes, node_id)
  defp step(_no_graph, _node_id), do: :error

  defp graphs(tasks) do
    tasks
    |> Enum.filter(& &1.instance_id)
    |> Enum.uniq_by(& &1.instance_id)
    |> Enum.group_by(& &1.organization_id, & &1.instance_id)
    |> Enum.flat_map(fn {tenant, instance_ids} -> instances(tenant, instance_ids) end)
    |> Map.new(fn {instance, tenant} -> {instance.id, graph(instance, tenant)} end)
  end

  # An instance that cannot be read leaves no graph, so its tasks resolve as
  # :unresolved rather than as declaring none.
  defp instances(tenant, ids) do
    AshEnterprise.Bpmn.Instance
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read(Scope.engine(%Scope{tenant: tenant}))
    |> case do
      {:ok, instances} -> Enum.map(instances, &{&1, tenant})
      {:error, _error} -> []
    end
  end

  defp graph(instance, tenant) do
    loader = AshBpmn.Config.definition_loader()

    case loader.load(AshEnterprise.Bpmn.Definition, instance.definition_id, instance, %{
           tenant: tenant
         }) do
      {:ok, %{graph: graph}} -> graph
      _not_found -> nil
    end
  end
end
