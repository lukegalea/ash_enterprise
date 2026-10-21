defmodule AshEnterpriseWeb.FlightLive do
  @moduledoc """
  The process flight views: `/app/flights` (one run), `/app/flights/briefs`
  and `/app/flights/stewardship` (every run of one process).

  Each page is one `AshA2ui.LiveRenderer` over a surface in
  `AshEnterpriseWeb.A2ui.FlightUI` and its siblings — the same UI modules the
  ACP server serves — whose diagram is `AshEnterprise.Process.FlightDiagram`.
  What this module adds is the live part: on the connected mount it subscribes
  to the process engine's token broadcasts for what the page draws
  (`AshBpmn.FlightView` topics), and every broadcast prompts the renderer's
  debounced refresh, which reads the markers again as the signed-in person.
  The broadcast carries nothing that is shown.

  ## One drawing per page

  A diagram's mermaid source is drawn when the surface is built; a refresh
  moves its markers but cannot redraw it. A run on another process is a
  different drawing, so changing the selected run (the browser's back and
  forward through `?ctx[instance]=`) navigates to a fresh page rather than
  patching this one. With no run selected, the page pins the newest running
  run the person may see at mount, so a newer run starting meanwhile does not
  swap the drawing from under its markers.
  """

  defmodule Surface do
    @moduledoc false

    defmacro __using__(opts) do
      ui = Keyword.fetch!(opts, :ui)
      view = Keyword.fetch!(opts, :view)

      quote do
        use AshA2ui.LiveRenderer,
          ui: unquote(ui),
          deep_link: true,
          actor_fn: &__MODULE__.actor/1,
          tenant_fn: &__MODULE__.tenant/1,
          # Topics are per page (which run, which process), so they are
          # subscribed on mount; configuring :pubsub is what makes any
          # broadcast this process receives a refresh.
          pubsub: [module: AshEnterprise.PubSub, topics: []]

        alias AshEnterprise.Security.ActorContext
        alias AshEnterpriseWeb.FlightLive

        def actor(socket), do: socket.assigns[:current_user]
        def tenant(socket), do: ActorContext.tenant(socket.assigns[:current_user])

        @impl true
        def mount(params, session, socket) do
          {params, socket} = FlightLive.subscribe(unquote(view), params, socket)
          AshA2ui.LiveRenderer.mount(__ash_a2ui_config__(), params, session, socket)
        end

        unquote(
          if view == :instance do
            quote do
              @impl true
              def handle_params(params, uri, socket) do
                case FlightLive.redraw(params, uri, socket) do
                  {:navigate, socket} ->
                    {:noreply, socket}

                  :same ->
                    AshA2ui.LiveRenderer.handle_params(__ash_a2ui_config__(), params, uri, socket)
                end
              end
            end
          end
        )

        @impl true
        def render(assigns), do: AshEnterpriseWeb.A2uiLive.Chrome.page(assigns)
      end
    end
  end

  import Phoenix.LiveView, only: [connected?: 1, push_navigate: 2]

  alias AshBpmn.FlightView
  alias AshEnterprise.Process.FlightDiagram
  alias AshEnterprise.Security.ActorContext

  @doc false
  # On the connected mount: which run (or process) the page draws, and the
  # engine topics it listens on. A one-run page with no selection pins the
  # newest run the person may read (an authorized read) into its params.
  def subscribe(view, params, socket) do
    if connected?(socket) do
      actor = socket.assigns[:current_user]
      tenant = ActorContext.tenant(actor)
      {params, drawn} = drawn(view, params, actor, tenant)

      for topic <- FlightDiagram.topics(drawn, tenant), do: FlightView.subscribe(topic)

      # What the page was asked to draw (the URL's run, or the pinned newest),
      # which a later URL is compared against — not whether it could be read.
      {params, Phoenix.Component.assign(socket, :flight_requested, selected(params))}
    else
      {params, socket}
    end
  end

  defp drawn(:instance, params, actor, tenant) do
    case selected(params) do
      nil ->
        case FlightDiagram.instance_for(nil, actor, tenant) do
          nil -> {params, {:instance, nil}}
          instance -> {put_selected(params, instance.id), {:instance, instance.id}}
        end

      id ->
        # Subscribe only to a run the person may read; anything else draws nothing.
        case FlightDiagram.instance_for(id, actor, tenant) do
          nil -> {params, {:instance, nil}}
          instance -> {params, {:instance, instance.id}}
        end
    end
  end

  defp drawn({:process, key}, params, _actor, _tenant), do: {params, {:process, key}}

  @doc false
  # A one-run page whose URL now names another run is redrawn from scratch.
  def redraw(params, uri, socket) do
    case {connected?(socket), socket.assigns[:flight_requested], selected(params)} do
      {true, requested, wanted} when is_binary(wanted) and wanted != requested ->
        %URI{path: path, query: query} = URI.parse(uri)
        to = if query in [nil, ""], do: path, else: path <> "?" <> query
        {:navigate, push_navigate(socket, to: to)}

      _same ->
        :same
    end
  end

  defp selected(%{"ctx" => %{"instance" => id}}) when is_binary(id) and id != "", do: id
  defp selected(_params), do: nil

  defp put_selected(params, id) when is_map(params),
    do: Map.update(params, "ctx", %{"instance" => id}, &Map.put(&1, "instance", id))

  defp put_selected(_not_routed, id), do: %{"ctx" => %{"instance" => id}}

  defmodule Instance do
    @moduledoc "One process run on its flight view (`/app/flights`)."
    use AshEnterpriseWeb.FlightLive.Surface, ui: AshEnterpriseWeb.A2ui.FlightUI, view: :instance
  end

  defmodule Briefs do
    @moduledoc "Every running morning brief on the `morning.brief` process (`/app/flights/briefs`)."
    use AshEnterpriseWeb.FlightLive.Surface,
      ui: AshEnterpriseWeb.A2ui.BriefFlightUI,
      view: {:process, "morning.brief"}
  end

  defmodule Stewardship do
    @moduledoc "Every steward review under way (`/app/flights/stewardship`)."
    use AshEnterpriseWeb.FlightLive.Surface,
      ui: AshEnterpriseWeb.A2ui.StewardFlightUI,
      view: {:process, "mdm.steward_review"}
  end
end
