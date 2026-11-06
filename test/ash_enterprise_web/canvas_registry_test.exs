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

  describe "consequences come from the effects declaration" do
    test "a declared action carries its declared consequence" do
      # Ash derives `:mutation` for every generic action; the declaration says
      # approving a task cannot be undone (MCP's default), so the canvas asks.
      assert %{consequence: :destructive, confirmation: :required} =
               capability("resource:bpmn.human_task", "approve")

      assert %{consequence: :mutation, confirmation: :none} =
               capability("resource:security.user_role", "request_assignment")

      assert %{consequence: :read, confirmation: :none} =
               capability("resource:accounts.team", "read")
    end

    test "an undeclared action keeps the consequence the canvas derives" do
      refute AshAgent.Effects.Info.declared?(AshEnterprise.Accounts.Team, :destroy)

      assert %{consequence: :destructive, confirmation: :required} =
               capability("resource:accounts.team", "destroy")
    end

    test "nothing undeclared, unknown or outside Ash is given a consequence" do
      assert Registry.consequence(AshEnterprise.Accounts.Team, :destroy, :destructive) == nil
      assert Registry.consequence(AshEnterprise.Accounts.Team, :no_such_action, :mutation) == nil
      assert Registry.consequence(String, :read, :read) == nil
    end
  end

  defp capability(ref, action_name) do
    {:ok, object} = AshA2ui.Canvas.resolve(ref, registry: Registry)

    Enum.find(object.capabilities, &(&1.action_name == action_name)) ||
      flunk("#{ref} #{action_name}")
  end

  defp edge_tuples(graph) do
    Enum.map(graph.edges, &{&1.kind, &1.from, &1.to, &1.name})
  end
end
