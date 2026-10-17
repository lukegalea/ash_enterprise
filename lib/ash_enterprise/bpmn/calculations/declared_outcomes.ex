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
  declares none.
  """

  use Ash.Resource.Calculation

  require Ash.Query

  alias AshBpmn.Scope

  @impl true
  def load(_query, _opts, _context), do: [:instance_id, :node_id, :organization_id]

  @impl true
  def calculate(tasks, _opts, _context) do
    graphs = graphs(tasks)

    Enum.map(tasks, fn task ->
      case get_in(graphs, [task.instance_id, "nodes", task.node_id, "outcomes"]) do
        [_ | _] = outcomes -> outcomes
        _none -> nil
      end
    end)
  end

  defp graphs(tasks) do
    tasks
    |> Enum.filter(& &1.instance_id)
    |> Enum.uniq_by(& &1.instance_id)
    |> Enum.group_by(& &1.organization_id, & &1.instance_id)
    |> Enum.flat_map(fn {tenant, instance_ids} -> instances(tenant, instance_ids) end)
    |> Map.new(fn {instance, tenant} -> {instance.id, graph(instance, tenant)} end)
  end

  defp instances(tenant, ids) do
    AshEnterprise.Bpmn.Instance
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!(Scope.engine(%Scope{tenant: tenant}))
    |> Enum.map(&{&1, tenant})
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
