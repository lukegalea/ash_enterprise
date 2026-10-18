defmodule AshEnterpriseWeb.PinnedAppLive do
  @moduledoc """
  `/app/mine/<id>` — one of the person's pinned apps: a surface they composed
  in the agent chat and pinned (`AshEnterprise.Assistant.PinnedApp`).

  The stored spec is never trusted: on every load it is resolved again
  against the composer's allowlist (`AshEnterprise.Assistant.Composer.reload/2`,
  which runs every verifier), and the rows are read as the person. A spec that
  no longer resolves shows its reasons and an Unpin button, not a stale table.
  Somebody else's id is "not found": pins are owner-only.

  Hosted through `AshEnterpriseWeb.A2ui.Host` like the helper's composed
  surfaces: client actions go to the surface held here, never one rebuilt from
  the client, and a resource that publishes keeps the surface live.
  """

  use AshEnterpriseWeb, :live_view

  alias AshEnterprise.Assistant.{Composer, PinnedApp}
  alias AshEnterprise.Security.ActorContext
  alias AshEnterpriseWeb.A2ui.Host
  alias AshEnterpriseWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       app: nil,
       presentation: nil,
       refused: nil,
       refresh_scheduled?: false,
       page_title: "My app"
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    if connected?(socket) do
      opts = actor_opts(socket)
      {:noreply, start_async(socket, :app, fn -> load(id, opts) end)}
    else
      {:noreply, socket}
    end
  end

  defp load(id, opts) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, app} <- PinnedApp.get(uuid, opts) do
      {:ok, app, Composer.reload(app.spec, surface_id: "mine_" <> String.slice(app.id, 0, 8))}
    else
      _ -> :not_found
    end
  end

  @impl true
  def handle_async(:app, {:ok, {:ok, app, {:ok, surface}}}, socket) do
    {socket, presentation} =
      Host.present(socket, Host.dynamic(surface, app.title), actor_opts(socket))

    {:noreply, assign(socket, app: app, page_title: app.title, presentation: presentation)}
  end

  def handle_async(:app, {:ok, {:ok, app, {:error, reasons}}}, socket),
    do: {:noreply, assign(socket, app: app, page_title: app.title, refused: reasons)}

  def handle_async(:app, _not_found, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "That app was not found, or is not yours.")
     |> push_navigate(to: ~p"/app")}
  end

  @impl true
  # An explicit gate before the write (iron law 11): the person must be one
  # who may unpin (self-service: an active member in their own tenant), and
  # the action then finds the pin among their own.
  def handle_event("unpin", _params, %{assigns: %{app: %PinnedApp{} = app}} = socket) do
    actor = socket.assigns.current_user

    with true <- Ash.can?({PinnedApp, :unpin}, actor, tenant: ActorContext.tenant(actor)),
         :ok <- PinnedApp.unpin(app.id, actor_opts(socket)) do
      {:noreply, socket |> put_flash(:info, "Unpinned.") |> push_navigate(to: ~p"/app")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not unpin it. Try again.")}
    end
  end

  def handle_event("unpin", _params, socket), do: {:noreply, socket}

  # Routed to the surface held here, through the handler (authorized as the
  # person); with nothing shown there is nothing an envelope can refer to.
  def handle_event(
        "a2ui:action",
        envelope,
        %{assigns: %{presentation: %{} = presentation}} = socket
      ) do
    {socket, presentation} =
      Host.handle_action(socket, presentation, envelope, actor_opts(socket))

    {:noreply, assign(socket, :presentation, presentation)}
  end

  def handle_event("a2ui:action", _envelope, socket), do: {:noreply, socket}

  def handle_event("a2ui:open_surface", args, socket), do: Host.open_surface(args, socket)

  @impl true
  def handle_info({:ash_a2ui_host, :refresh}, %{assigns: %{presentation: %{} = p}} = socket) do
    {socket, presentation} = Host.refresh(socket, p, actor_opts(socket))
    {:noreply, assign(socket, presentation: presentation, refresh_scheduled?: false)}
  end

  def handle_info({:ash_a2ui_host, :refresh}, socket),
    do: {:noreply, assign(socket, :refresh_scheduled?, false)}

  # Anything else is a notification on the surface's topics: coalesce it.
  def handle_info(_notification, %{assigns: %{presentation: %{}}} = socket) do
    case Host.schedule_refresh(socket.assigns.refresh_scheduled?) do
      :scheduled -> {:noreply, assign(socket, :refresh_scheduled?, true)}
      :already_scheduled -> {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp actor_opts(socket) do
    actor = socket.assigns.current_user
    [actor: actor, tenant: ActorContext.tenant(actor), authorize?: true]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={assigns[:page]} width="max-w-7xl">
      <div class="space-y-4">
        <header class="flex flex-wrap items-start justify-between gap-3">
          <div class="space-y-1">
            <p class="text-xs font-heading uppercase tracking-wide text-foreground/60">My app</p>
            <h1 id="pinned-title" class="font-display text-2xl tracking-tight">
              {(@app && @app.title) || "Loading…"}
            </h1>
            <p class="text-sm text-foreground/70">
              Composed in the agent chat and pinned by you. Checked against the schema each time it
              opens, and read as you.
            </p>
          </div>
          <div class="flex items-center gap-2">
            <.button navigate={~p"/app/agent"} size="sm" variant="ghost">
              <.icon name="hero-sparkles" class="size-4" /> Agent
            </.button>
            <.button :if={@app} id="unpin" type="button" size="sm" phx-click="unpin">
              <.icon name="hero-bookmark-slash" class="size-4" /> Unpin
            </.button>
          </div>
        </header>

        <.callout :if={@refused} id="pinned-refused" kind={:warning}>
          <p>This app no longer matches the data it was composed over, so it is not shown:</p>
          <ul class="ms-5 list-disc text-sm">
            <li :for={reason <- Enum.take(@refused, 5)}>{reason}</li>
          </ul>
        </.callout>

        {AshA2ui.LiveRenderer.surface_container(assigns)}
      </div>
    </Layouts.app>
    """
  end
end
