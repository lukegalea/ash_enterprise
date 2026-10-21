defmodule AshEnterprise.Bpmn.Calculations.StageLabel do
  @moduledoc """
  Where a process run stands, in words: `At Approve the brief`, `Completed ·
  approved`, `Failed`, `Cancelled`.

  A running instance is placed by its live tokens, read under the reader's
  policies, and named by the steps of the definition it pinned (found as the
  engine finds it, `AshEnterprise.Process.DefinitionLoader`: configuration,
  not data about anyone). A run whose tokens the reader may not read is
  `Running`.
  """

  use Ash.Resource.Calculation

  require Ash.Query

  alias AshEnterprise.Bpmn.{Definition, Token}
  alias AshEnterprise.Process.DefinitionLoader

  @impl true
  def load(_query, _opts, _context), do: [:status, :outcome, :definition_id, :organization_id]

  @impl true
  def calculate(instances, _opts, context) do
    running = for %{status: :running, id: id} <- instances, do: id
    tokens = tokens(running, context)
    graphs = graphs(Enum.filter(instances, &(&1.status == :running)))

    {:ok, Enum.map(instances, &label(&1, tokens, graphs))}
  end

  defp label(%{status: :running} = instance, tokens, graphs) do
    graph = Map.get(graphs, instance.definition_id, %{})

    case Map.get(tokens, instance.id, []) do
      [] ->
        "Running"

      node_ids ->
        names =
          node_ids
          |> Enum.map(&(get_in(graph, ["nodes", &1, "name"]) || &1))
          |> Enum.uniq()
          |> Enum.join(", ")

        "At #{names}"
    end
  end

  defp label(%{status: :completed, outcome: outcome}, _tokens, _graphs)
       when is_binary(outcome) and outcome != "",
       do: "Completed · #{outcome}"

  defp label(%{status: status}, _tokens, _graphs),
    do: status |> to_string() |> String.capitalize()

  defp tokens([], _context), do: %{}

  defp tokens(instance_ids, context) do
    Token
    |> Ash.Query.filter(
      instance_id in ^instance_ids and status in [:active, :executing, :waiting]
    )
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.read!(Ash.Context.to_opts(context))
    |> Enum.group_by(& &1.instance_id, & &1.node_id)
  end

  defp graphs(instances) do
    instances
    |> Enum.uniq_by(& &1.definition_id)
    |> Map.new(fn instance ->
      case DefinitionLoader.load(Definition, instance.definition_id, instance, %{
             tenant: instance.organization_id
           }) do
        {:ok, definition} -> {instance.definition_id, definition.graph || %{}}
        {:error, _not_found} -> {instance.definition_id, %{}}
      end
    end)
  end
end
