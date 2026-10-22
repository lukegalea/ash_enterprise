defmodule AshEnterpriseWeb.LineageLive do
  @moduledoc """
  `/app/lineage` — the Lineage app: one `AshA2ui.LiveRenderer` over
  `AshEnterpriseWeb.A2ui.LineageUI`, read as the signed-in person in their
  tenant.

  What this module adds to the stock renderer:

    * **Live.** It subscribes to the tenant's lineage topic
      (`AshEnterprise.Lineage.Recorder.topic/1`), which the store broadcasts
      on after every write. Each broadcast refreshes the data model
      (debounced): the diagram's markers move, a run that failed turns red,
      the runs table gains its row.
    * **Redraw when the graph changes.** The diagram's mermaid source is drawn
      once per surface build; markers move, the drawing does not. So when the
      `window` or `job` picker changes, or a broadcast brings a job or dataset
      the drawing does not have, the page navigates to itself, which rebuilds
      the surface with the selections it carries in its URL (`ctx[...]`).

  The source comparison runs off the LiveView process (`start_async/3`), as
  every read here does.
  """

  use AshA2ui.LiveRenderer,
    ui: AshEnterpriseWeb.A2ui.LineageUI,
    deep_link: true,
    actor_fn: &__MODULE__.actor/1,
    tenant_fn: &__MODULE__.tenant/1,
    pubsub: [module: AshEnterprise.PubSub, topics: []]

  alias AshEnterprise.Lineage.{Diagram, Graph, Recorder}
  alias AshEnterprise.Security.ActorContext
  alias AshEnterpriseWeb.Layouts

  @doc false
  def actor(socket), do: socket.assigns[:current_user]

  @doc false
  def tenant(socket), do: ActorContext.tenant(socket.assigns[:current_user])

  @impl true
  def mount(params, session, socket) do
    {:ok, socket} = AshA2ui.LiveRenderer.mount(__ash_a2ui_config__(), params, session, socket)

    socket = assign(socket, lineage_filters: filters(params), lineage_source: nil)

    case connected?(socket) && tenant(socket) do
      tenant when is_binary(tenant) ->
        Phoenix.PubSub.subscribe(AshEnterprise.PubSub, Recorder.topic(tenant))
        {:ok, check_source(socket)}

      _not_connected_or_no_tenant ->
        {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    if connected?(socket) and filters(params) != socket.assigns.lineage_filters do
      {:noreply, push_navigate(socket, to: path(uri))}
    else
      AshA2ui.LiveRenderer.handle_params(__ash_a2ui_config__(), params, uri, socket)
    end
  end

  @impl true
  def handle_info({:lineage_recorded, _tenant} = message, socket) do
    {:noreply, socket} =
      AshA2ui.LiveRenderer.handle_notification(__ash_a2ui_config__(), message, socket)

    {:noreply, check_source(socket)}
  end

  def handle_info(message, socket),
    do: AshA2ui.LiveRenderer.handle_notification(__ash_a2ui_config__(), message, socket)

  @impl true
  def handle_async(:lineage_source, {:ok, source}, socket) do
    case socket.assigns.lineage_source do
      nil -> {:noreply, assign(socket, :lineage_source, source)}
      ^source -> {:noreply, socket}
      _drawn -> {:noreply, push_navigate(socket, to: current_path(socket))}
    end
  end

  # An unreadable graph is a diagram marked unavailable, not a crashed page.
  def handle_async(:lineage_source, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async(:ash_a2ui_surface, result, socket),
    do:
      AshA2ui.LiveRenderer.handle_async(__ash_a2ui_config__(), :ash_a2ui_surface, result, socket)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={assigns[:page]} width="max-w-7xl">
      {AshA2ui.LiveRenderer.surface_container(assigns)}
    </Layouts.app>
    """
  end

  # The selections that change the drawing (the run selection only changes
  # the detail, which the data model carries).
  defp filters(params) do
    ctx = if is_map(params["ctx"]), do: params["ctx"], else: %{}
    {ctx["window"], ctx["job"]}
  end

  defp check_source(socket) do
    {window, job} = socket.assigns.lineage_filters
    opts = [actor: actor(socket), tenant: tenant(socket), window: window, job_id: job]

    start_async(socket, :lineage_source, fn ->
      case Graph.derive(opts) do
        {:ok, graph} -> Diagram.mermaid(graph)
        {:error, _error} -> :unreadable
      end
    end)
  end

  defp current_path(socket) do
    case socket.assigns[:ash_a2ui_uri] do
      uri when is_binary(uri) -> path(uri)
      _no_uri -> "/app/lineage"
    end
  end

  defp path(uri) do
    case URI.parse(uri) do
      %URI{path: path, query: nil} -> path || "/app/lineage"
      %URI{path: path, query: query} -> (path || "/app/lineage") <> "?" <> query
    end
  end
end
