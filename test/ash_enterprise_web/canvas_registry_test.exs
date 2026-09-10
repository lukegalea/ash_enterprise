defmodule AshEnterpriseWeb.CanvasRegistryTest do
  @moduledoc """
  The host canvas registry is complete: every Ash domain the application
  ships — and every resource those domains declare — appears in the built
  graph under its stable opaque id. This is the dev surface's "same
  visibility as Clarity" promise, asserted rather than promised.
  """

  use ExUnit.Case, async: true

  alias Ash.Domain.Info, as: DomainInfo
  alias AshEnterprise.Canvas.Registry

  test "every application domain appears as a domain node" do
    graph = AshA2ui.Canvas.build_graph(Registry)

    for domain <- Registry.domains() do
      short = domain |> DomainInfo.short_name() |> Atom.to_string()
      node_id = "domain:" <> short

      assert Map.has_key?(graph.nodes, node_id),
             "domain #{inspect(domain)} (#{node_id}) is missing from the graph"

      assert graph.nodes[node_id].kind == :domain
      assert {:contains, "application:registry", node_id, nil} in edge_tuples(graph)
    end
  end

  test "every declared resource appears as a resource node under its domain" do
    graph = AshA2ui.Canvas.build_graph(Registry)

    for domain <- Registry.domains() do
      domain_short = domain |> DomainInfo.short_name() |> Atom.to_string()

      for resource <- DomainInfo.resources(domain) do
        resource_short =
          resource |> Module.split() |> List.last() |> Macro.underscore()

        node_id = "resource:" <> domain_short <> "." <> resource_short

        assert Map.has_key?(graph.nodes, node_id),
               "resource #{inspect(resource)} (#{node_id}) is missing from the graph"

        assert graph.nodes[node_id].kind == :resource
        assert {:contains, "domain:" <> domain_short, node_id, nil} in edge_tuples(graph)
      end
    end
  end

  test "the graph is rooted at the application node and revises deterministically" do
    graph = AshA2ui.Canvas.build_graph(Registry)

    assert graph.roots == ["application:registry"]
    assert graph.revision == AshA2ui.Canvas.build_graph(Registry).revision
  end

  defp edge_tuples(graph) do
    Enum.map(graph.edges, &{&1.kind, &1.from, &1.to, &1.name})
  end
end
