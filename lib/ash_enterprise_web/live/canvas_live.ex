defmodule AshEnterpriseWeb.CanvasLive do
  @moduledoc """
  The dev-only `/canvas` surface: the application's domains, resources and
  relationships as a navigable object graph, with a server-resolved
  naked-object inspector on selection.

  The graph itself is rendered by the `<ash-canvas-graph>` Lit element
  (driver lane, Cytoscape under the hood) through the `AshCanvas` hook. This
  LiveView owns the two server sides of that contract:

    * on connected mount it builds the graph with
      `AshA2ui.Canvas.build_graph/1` over `AshEnterprise.Canvas.Registry`
      and pushes it once as `"canvas:graph"` — structural nodes only. No
      record is ever a node, and no read happens at all: the graph is
      declared metadata, not a query (`A2UI-103/AC-4`).
    * `handle_event("canvas:select", …)` is the *only* client event that
      exists. It resolves one opaque ref through
      `AshA2ui.Canvas.resolve/2` under the signed-in actor and tenant and
      re-renders the inspector. There is no event that can request records:
      a record enters the picture only when someone resolves a record ref,
      which is an authorized read, and a ref the actor cannot read is the
      same fail-closed `{:error, :unknown_object}` as garbage.

  The inspector is server-rendered HEEx — deliberately not an A2UI surface —
  because its job is to *show what the library knows* (provenance,
  capabilities, projections) rather than to be one of the projections it
  describes. Where a resource has a declared app surface, the browse
  projection becomes a link to it via `AshEnterpriseWeb.A2ui.Surfaces`.
  """

  use AshEnterpriseWeb, :live_view

  alias AshA2ui.Canvas
  alias AshA2ui.Canvas.Object
  alias AshEnterprise.Canvas.Registry
  alias AshEnterprise.Security.ActorContext
  alias AshEnterpriseWeb.A2ui.Host
  alias AshEnterpriseWeb.A2ui.Surfaces

  @impl true
  def mount(_params, _session, socket) do
    graph = Canvas.build_graph(Registry)

    socket =
      assign(socket,
        revision: graph.revision,
        node_count: map_size(graph.nodes),
        relationship_count: Enum.count(graph.edges, &(&1.kind == :relationship)),
        selected: nil,
        selection_error: nil,
        presentation: nil,
        refresh_scheduled?: false
      )

    if connected?(socket) do
      {:ok, push_event(socket, "canvas:graph", graph_payload(graph))}
    else
      {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={assigns[:current_scope]} width="max-w-7xl">
      <div class="space-y-4">
        <header class="space-y-1">
          <h1 class="text-2xl font-semibold">Canvas</h1>
          <p class="text-sm opacity-70">
            The application's domains, resources and relationships as one
            object graph. Dev-only — the same audience /clarity serves.
            Selection resolves a naked object server-side; no records are ever
            part of the graph.
          </p>
          <p class="text-xs">
            Revision <code class="font-mono">{String.slice(@revision, 0, 19)}…</code>
            · {@node_count} nodes · {@relationship_count} relationship edges
          </p>
        </header>

        <%!--
          The height is load-bearing, not styling. `<ash-canvas-graph>` is
          `height: 100%` against this element, and its two panes are a CSS grid
          -- so with no definite height here, the grid's row is sized by its
          tallest content, which is the outline list. At 68 resources that list
          is around 1900px, the canvas frame becomes 1900px with it, and
          Cytoscape dutifully fits the graph into that box and centres it: the
          graph ends up ~950px down, below the fold, drawn small enough to read
          as an empty canvas. Every check short of looking at the pixels passes,
          because the data, the nodes and the fit are all correct.

          Bounding the height puts the outline back on its own scrollbar
          (`.cv-tree-scroll` is already `overflow-y: auto; min-height: 0`,
          built for exactly this) and gives the graph the viewport.
        --%>
        <div
          id="canvas-graph"
          phx-hook="AshCanvas"
          phx-update="ignore"
          aria-label="Canvas object graph"
          class="h-[72vh] min-h-[30rem]"
        >
          <%!-- The Lit element owns this subtree (phx-update="ignore"). --%>
        </div>

        <%!--
          The container is rendered ALWAYS and hidden with a class, never
          removed. `Host.present/3` delivers the surface by pushing an event to
          the `AshA2ui` hook, and a hook that does not exist yet receives
          nothing -- so rendering this conditionally means the first selection
          pushes into a void and the panel stays blank. Same reason AgentLive
          keeps its container mounted.
        --%>
        <section
          class={["space-y-2", if(!@presentation, do: "hidden")]}
          aria-label="Surface for the selected resource"
        >
          {AshA2ui.LiveRenderer.surface_container(assigns)}
        </section>

        <div id="canvas-inspector" class="space-y-3">
          <%= if @selection_error == :unknown_object do %>
            <div class="alert alert-warning" role="status">
              <.icon name="hero-exclamation-triangle" class="size-5" />
              <span>Unknown object — the reference does not name anything this canvas exposes.</span>
            </div>
          <% end %>

          <%= if @selected do %>
            <.inspector object={@selected} surface={surface_for(@selected)} />
          <% else %>
            <p class="text-sm opacity-60">
              Select a node in the graph to inspect it.
            </p>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @doc false
  # The inspector panel: label + kind badge, provenance display names,
  # capabilities, projections, and the browse link when the resource has a
  # declared app surface.
  attr :object, Object, required: true
  attr :surface, :map, default: nil

  def inspector(assigns) do
    ~H"""
    <section class="card bg-base-100 border border-base-300">
      <div class="card-body gap-4">
        <div class="flex items-center gap-3">
          <span class="badge badge-outline font-mono text-xs">{@object.ref.kind}</span>
          <h2 class="card-title text-lg">{@object.label}</h2>
          <code class="font-mono text-xs opacity-60">{@object.ref.id}</code>
        </div>

        <div>
          <h3 class="text-xs font-semibold uppercase opacity-60">Provenance</h3>
          <ul class="text-sm">
            <li :for={{role, module} <- provenance_rows(@object)}>
              <span class="opacity-60">{role}:</span>
              <code class="font-mono">{display_name(module)}</code>
            </li>
          </ul>
        </div>

        <div>
          <h3 class="text-xs font-semibold uppercase opacity-60">Capabilities</h3>
          <ul class="divide-y divide-base-300 text-sm">
            <li
              :for={capability <- @object.capabilities}
              class="flex flex-wrap items-center gap-2 py-1"
            >
              <span class="font-medium">{capability.label}</span>
              <span class="badge badge-ghost">{capability.consequence}</span>
              <span :if={capability.confirmation == :required} class="badge badge-warning">
                confirmation required
              </span>
              <span class={[
                "badge",
                capability.authorized? && "badge-success",
                !capability.authorized? && "badge-ghost opacity-60"
              ]}>
                {if capability.authorized?, do: "authorized", else: "not authorized"}
              </span>
            </li>
          </ul>
        </div>

        <div>
          <h3 class="text-xs font-semibold uppercase opacity-60">Projections</h3>
          <div class="flex flex-wrap gap-2">
            <span
              :for={projection <- @object.projections}
              class="badge badge-outline font-mono text-xs"
            >
              {projection}
            </span>
          </div>
          <.link
            :if={@surface}
            navigate={@surface.path}
            class="btn btn-sm btn-primary mt-3"
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Browse in {@surface.label}
          </.link>
        </div>
      </div>
    </section>
    """
  end

  @impl true
  def handle_event("canvas:select", %{"ref" => ref}, socket) when is_binary(ref) do
    actor = socket.assigns[:current_user]
    tenant = actor && ActorContext.tenant(actor)

    case select(ref, actor, tenant) do
      {:ok, object} ->
        socket =
          socket
          |> assign(selected: object, selection_error: nil)
          |> show_surface(surface_for(object), actor, tenant)

        {:noreply, socket}

      {:error, :unknown_object} ->
        socket =
          socket
          |> assign(selected: nil, selection_error: :unknown_object)
          |> show_surface(nil, actor, tenant)

        {:noreply, socket}
    end
  end

  def handle_event("canvas:select", _malformed, socket) do
    {:noreply, assign(socket, selected: nil, selection_error: :unknown_object)}
  end

  # The client interacted with the rendered surface. Routed through `Host`
  # rather than into an Ash action directly: the handler is what enforces the
  # row-action allowlist, `visible_when`, and the error contract that puts
  # validation messages on the reserved `/errors/<field>` paths.
  def handle_event("a2ui:action", envelope, %{assigns: %{presentation: nil}} = socket) do
    # Nothing is being shown, so there is nothing this envelope can refer to.
    # Rebuilding a surface from something the client echoed back is the
    # tamper-proofing hole the server-held presentation exists to close.
    _ = envelope
    {:noreply, socket}
  end

  def handle_event("a2ui:action", envelope, socket) do
    actor = socket.assigns[:current_user]

    {socket, presentation} =
      Host.handle_action(socket, socket.assigns.presentation, envelope,
        actor: actor,
        tenant: actor && ActorContext.tenant(actor)
      )

    {:noreply, assign(socket, :presentation, presentation)}
  end

  @impl true
  def handle_info({:ash_a2ui_host, :refresh}, %{assigns: %{presentation: nil}} = socket) do
    {:noreply, assign(socket, :refresh_scheduled?, false)}
  end

  def handle_info({:ash_a2ui_host, :refresh}, socket) do
    actor = socket.assigns[:current_user]

    {socket, presentation} =
      Host.refresh(socket, socket.assigns.presentation,
        actor: actor,
        tenant: actor && ActorContext.tenant(actor)
      )

    {:noreply,
     socket
     |> assign(:presentation, presentation)
     |> assign(:refresh_scheduled?, false)}
  end

  # Anything else while a surface is subscribed is a notification on one of its
  # topics. Ash's PubSub notifier can send a %Notification{}, a
  # %Phoenix.Socket.Broadcast{} or a bare map depending on `broadcast_type`, so
  # this matches on none of them and coalesces whatever arrives.
  def handle_info(_message, %{assigns: %{presentation: nil}} = socket), do: {:noreply, socket}

  def handle_info(_message, socket) do
    case Host.schedule_refresh(socket.assigns.refresh_scheduled?) do
      :scheduled -> {:noreply, assign(socket, :refresh_scheduled?, true)}
      :already_scheduled -> {:noreply, socket}
    end
  end

  # Selecting a resource that publishes a surface renders that surface, live,
  # under the graph -- the same experience-v2 screen `/app/users` serves, built
  # by the same host seam the helper console uses, and filtered by the selected
  # actor's own policies.
  #
  # The previous selection's subscription is dropped first. Without it, walking
  # the graph leaves the LiveView subscribed to every surface it passed through,
  # and a write to any of them refreshes one nobody is looking at.
  defp show_surface(socket, nil, _actor, _tenant) do
    Host.dismiss(socket.assigns.presentation)
    assign(socket, :presentation, nil)
  end

  defp show_surface(socket, surface, actor, tenant) do
    Host.dismiss(socket.assigns.presentation)

    {socket, presentation} =
      Host.present(socket, Host.declared(surface), actor: actor, tenant: tenant)

    assign(socket, :presentation, presentation)
  end

  @doc false
  # The selection seam, separate from the socket so the fail-closed contract
  # is testable without a route: exactly the library's resolve, with the
  # signed-in actor and tenant — and exactly its fail-closed error.
  @spec select(String.t() | term, term, term) ::
          {:ok, Object.t()} | {:error, :unknown_object}
  def select(ref, actor, tenant) do
    Canvas.resolve(ref, registry: Registry, actor: actor, tenant: tenant)
  end

  @doc false
  # The wire form of a built graph (the contract's `canvas:graph` payload):
  # plain JSON-shaped maps, structural nodes only.
  @spec graph_payload(AshA2ui.Canvas.Graph.t()) :: %{
          String.t() => String.t() | [map()]
        }
  def graph_payload(graph) do
    %{
      "revision" => graph.revision,
      "nodes" =>
        graph.nodes
        |> Map.values()
        |> Enum.sort_by(& &1.id)
        |> Enum.map(fn node ->
          %{
            "id" => node.id,
            "kind" => to_string(node.kind),
            "label" => node.label,
            "metadata" => node.metadata
          }
        end),
      "edges" =>
        graph.edges
        |> Enum.sort_by(&{&1.from, &1.to, &1.kind, &1.name})
        |> Enum.map(fn edge ->
          %{
            "kind" => to_string(edge.kind),
            "from" => edge.from,
            "to" => edge.to,
            "name" => edge.name && to_string(edge.name)
          }
        end)
    }
  end

  # --- inspector helpers -------------------------------------------------------

  defp provenance_rows(%Object{provenance: provenance}) do
    provenance
    |> Enum.sort_by(fn {role, _module} -> role end)
    |> Enum.map(fn {role, module} -> {Atom.to_string(role), module} end)
  end

  defp display_name(module) when is_atom(module) do
    module
    |> Module.split()
    |> List.last()
    |> String.replace("_", " ")
  end

  defp display_name(other), do: inspect(other)

  # The declared A2UI surface for a resolved resource, when one exists —
  # what turns the browse projection into a real link.
  defp surface_for(%Object{ref: %{kind: :resource}, provenance: %{resource: resource}}) do
    Enum.find(Surfaces.all(), fn surface ->
      AshA2ui.Info.resource!(surface.ui) == resource
    end)
  rescue
    _not_an_a2ui_module -> nil
  end

  defp surface_for(_other_object), do: nil
end
