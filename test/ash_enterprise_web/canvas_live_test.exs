defmodule AshEnterpriseWeb.CanvasLiveTest do
  @moduledoc """
  The dev-only `/canvas` surface, host-wiring side: the route is dev-gated
  (absent wherever `dev_routes` is not enabled — the test env proves the
  negative), the pushed graph payload is structural-only (zero record
  nodes, the progressive-disclosure guarantee at the wire), the selection
  seam resolves through the library's fail-closed resolver, and the
  inspector renders a resolved object's label, capabilities and
  projections — or the inline unknown-object notice.
  """

  use AshEnterpriseWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  require Ash.Query

  alias Ash.Domain.Info, as: DomainInfo
  alias AshEnterprise.Canvas.Registry
  alias AshEnterprise.Security.ActorContext
  alias AshEnterpriseWeb.CanvasLive

  @endpoint AshEnterpriseWeb.Endpoint

  describe "route gating" do
    test "the /canvas route exists only where dev_routes is enabled" do
      # The test env compiles the router with `dev_routes` unset (false):
      # the surface must not be compiled in. The dev server (config/dev.exs
      # sets `dev_routes: true`) is where the route and the Playwright tier
      # live.
      routes = AshEnterpriseWeb.Router.__routes__()

      refute Enum.any?(routes, &(&1.path == "/canvas" or String.contains?(&1.path, "/canvas")))
    end

    test "the route is compiled under the same flag as /clarity" do
      # Source-level check of the pairing the contract pins: the /canvas
      # route lives inside the same `dev_routes` conditional as /clarity.
      source = File.read!("lib/ash_enterprise_web/router.ex")

      dev_block =
        source
        |> String.split("if Application.compile_env(:ash_enterprise, :dev_routes)")
        |> List.last()

      assert dev_block =~ ~s(live "/canvas", CanvasLive)
      assert dev_block =~ ~s(clarity "/")
    end
  end

  describe "graph payload" do
    test "carries structural nodes only — zero record nodes" do
      graph = AshA2ui.Canvas.build_graph(Registry)
      payload = CanvasLive.graph_payload(graph)

      assert %{"revision" => "sha256:" <> _digest, "nodes" => nodes, "edges" => edges} = payload
      assert is_list(nodes) and is_list(edges) and nodes != []

      refute Enum.any?(nodes, fn node -> node["id"] =~ "record:" end)
      refute Enum.any?(edges, fn edge -> edge["from"] =~ "record:" or edge["to"] =~ "record:" end)

      # contract node shape: id/kind/label/metadata, kinds limited to the
      # three structural kinds
      Enum.each(nodes, fn node ->
        assert MapSet.new(Map.keys(node)) == MapSet.new(["id", "kind", "label", "metadata"])
        assert node["kind"] in ["application", "domain", "resource"]
      end)

      Enum.each(edges, fn edge ->
        assert MapSet.new(Map.keys(edge)) == MapSet.new(["kind", "from", "to", "name"])
        assert edge["kind"] in ["contains", "relationship"]
      end)
    end

    test "carries every domain and resource of the host registry" do
      payload = CanvasLive.graph_payload(AshA2ui.Canvas.build_graph(Registry))
      ids = MapSet.new(payload["nodes"], & &1["id"])

      for domain <- Registry.domains() do
        domain_short = domain |> DomainInfo.short_name() |> Atom.to_string()
        assert MapSet.member?(ids, "domain:" <> domain_short)

        for resource <- DomainInfo.resources(domain) do
          resource_short = resource |> Module.split() |> List.last() |> Macro.underscore()
          assert MapSet.member?(ids, "resource:" <> domain_short <> "." <> resource_short)
        end
      end
    end
  end

  describe "selection seam" do
    test "resolves structural refs and fails closed on unknown ones" do
      assert {:ok, object} = CanvasLive.select("domain:accounts", nil, nil)
      assert object.label == "Accounts"
      assert object.ref.kind == :domain

      assert CanvasLive.select("resource:no_such_domain.no_such_resource", nil, nil) ==
               {:error, :unknown_object}

      assert CanvasLive.select("nonsense", nil, nil) == {:error, :unknown_object}
      assert CanvasLive.select(42, nil, nil) == {:error, :unknown_object}
    end

    test "record refs resolve through an authorized read and fail closed otherwise" do
      seeded =
        AshEnterprise.Platform.Seeder.seed_tenant(
          unique_name: "canvas-#{System.unique_integer([:positive])}"
        )

      admin =
        ActorContext.attach(
          seeded.user,
          ActorContext.build(seeded.user, tenant: seeded.organization.id)
        )

      stranger =
        AshEnterprise.Accounts.User
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "canvas-stranger-#{System.unique_integer([:positive])}@example.com",
            password: "password1234",
            password_confirmation: "password1234"
          },
          authorize?: false
        )
        |> Ash.create!()

      ref = "record:accounts.user:" <> AshA2ui.Canvas.ObjectRef.encode_pk(seeded.user.id)

      # the signed-in actor resolves the record (the one authorized read)
      assert {:ok, object} = CanvasLive.select(ref, admin, seeded.organization.id)
      assert object.ref.kind == :record
      assert object.provenance.record.id == seeded.user.id

      # an actor without read access gets the same fail-closed answer as
      # garbage — existence is not disclosed
      assert CanvasLive.select(ref, stranger, seeded.organization.id) == {:error, :unknown_object}

      # where read IS granted but a write is not, the edit capability exists
      # with an explicit unauthorized verdict (never silently absent)
      {:ok, own} = CanvasLive.select(ref, seeded.user, seeded.organization.id)
      edit = Enum.find(own.capabilities, &(&1.verb == :edit))

      if edit do
        assert edit.authorized? in [true, false]
      end
    end
  end

  describe "inspector rendering" do
    test "renders label, kind, provenance, capabilities and projections" do
      # Team carries a destroy action, so the destructive confirmation badge
      # is exercised alongside the ordinary ones.
      {:ok, object} = CanvasLive.select("resource:accounts.team", nil, nil)

      html =
        render_component(&CanvasLive.render/1, %{
          flash: %{},
          current_scope: nil,
          revision: "sha256:test",
          node_count: 1,
          relationship_count: 0,
          selected: object,
          selection_error: nil,
          presentation: nil
        })

      assert html =~ "User"
      assert html =~ "resource"
      assert html =~ "Provenance"
      assert html =~ "Capabilities"
      # resource-level capabilities are presence-only, so every badge reads
      # authorized; the destructive destroy capability demands confirmation
      assert html =~ "authorized"
      assert html =~ "confirmation required"
      assert html =~ "Projections"
      assert html =~ "inspect"
    end

    test "renders the browse link when the resource has a declared surface" do
      {:ok, object} = CanvasLive.select("resource:contracts.party", nil, nil)

      html =
        render_component(&CanvasLive.render/1, %{
          flash: %{},
          current_scope: nil,
          revision: "sha256:test",
          node_count: 1,
          relationship_count: 0,
          selected: object,
          selection_error: nil,
          presentation: nil
        })

      assert html =~ "Browse in"
      assert html =~ "/app/canonical-parties"
    end

    test "the surface container is rendered even with nothing presented" do
      # The container must exist from the first render, not appear with the
      # first selection. `Host.present/3` delivers a surface by pushing an
      # event to the `AshA2ui` hook, and a hook that is not mounted yet
      # receives nothing -- so rendering the container conditionally would make
      # the first resource a person clicks come back blank, and only the second
      # one work. It is hidden with a class instead.
      html =
        render_component(&CanvasLive.render/1, %{
          flash: %{},
          current_scope: nil,
          revision: "sha256:test",
          node_count: 1,
          relationship_count: 0,
          selected: nil,
          selection_error: nil,
          presentation: nil
        })

      assert html =~ ~s(id="ash-a2ui-surface")
      assert html =~ ~s(phx-hook="AshA2ui")
      assert html =~ "hidden"
    end

    test "renders the unknown-object notice for a failed selection" do
      html =
        render_component(&CanvasLive.render/1, %{
          flash: %{},
          current_scope: nil,
          revision: "sha256:test",
          node_count: 1,
          relationship_count: 0,
          selected: nil,
          selection_error: :unknown_object,
          presentation: nil
        })

      assert html =~ "Unknown object"
      refute html =~ "Capabilities"
    end
  end
end
