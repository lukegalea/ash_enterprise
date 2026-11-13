defmodule AshEnterpriseWeb.PinnedAppLive do
  @moduledoc """
  `/app/mine/<id>` — one of the person's pinned apps: a surface they composed
  in the agent chat and pinned (`AshEnterprise.Assistant.PinnedApp`).

  The stored spec is never trusted: on every load it is resolved again
  against the composer's allowlist (`AshEnterprise.Assistant.Composer.reload/2`,
  which runs every verifier and `Composer.approved/1`), and the rows are read
  as the person, with the grants they hold now. A background refresh rebuilds
  the person's actor context first, so a grant revoked while the page is open
  hides its rows at the next refresh, not only at the next visit. A spec that
  no longer resolves shows its reasons and an Unpin button, not a stale table.
  Somebody else's id is "not found": pins are owner-only.

  ## Two states, shown apart

  The header says whether the definition is valid and how fresh its rows
  are, as two badges (`AshEnterprise.Surfaces.SavedStatus`): a valid
  definition can show old rows, and an invalid one shows none, whose
  freshness is unknown rather than "fresh". Freshness is judged again every
  half minute, and Read again re-reads the rows as the person.

  Hosted through `AshEnterpriseWeb.A2ui.Host` like the helper's composed
  surfaces: client actions go to the surface held here, never one rebuilt from
  the client, and a resource that publishes keeps the surface live.
  """

  use AshEnterpriseWeb, :live_view

  alias AshEnterprise.Assistant.{Composer, PinnedApp}
  alias AshEnterprise.Platform.LocalTime
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Surfaces.SavedStatus
  alias AshEnterpriseWeb.A2ui.Host
  alias AshEnterpriseWeb.Layouts
  alias AshEnterpriseWeb.LiveUserAuth

  @tick_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       app: nil,
       presentation: nil,
       refused: nil,
       validity: :unknown,
       read_at: nil,
       now: DateTime.utc_now(),
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

    Process.send_after(self(), :freshness_tick, @tick_ms)

    {:noreply,
     socket
     |> assign(app: app, page_title: app.title, presentation: presentation)
     |> assign(validity: SavedStatus.validity({:ok, surface}))
     |> read_now()}
  end

  def handle_async(:app, {:ok, {:ok, app, {:error, reasons} = refused}}, socket) do
    {:noreply,
     assign(socket,
       app: app,
       page_title: app.title,
       refused: reasons,
       validity: SavedStatus.validity(refused)
     )}
  end

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

  # Reads the rows again as the person (the actor context was rebuilt before
  # this event, so with the grants they hold now); nothing shown, nothing read.
  def handle_event("reread", _params, %{assigns: %{presentation: %{} = presentation}} = socket) do
    {socket, presentation} = Host.refresh(socket, presentation, actor_opts(socket))
    {:noreply, socket |> assign(:presentation, presentation) |> read_now()}
  end

  def handle_event("reread", _params, socket), do: {:noreply, socket}

  # Routed to the surface held here, through the handler (authorized as the
  # person); with nothing shown there is nothing an message can refer to.
  def handle_event(
        "a2ui:message",
        message,
        %{assigns: %{presentation: %{} = presentation}} = socket
      ) do
    {socket, presentation} =
      Host.handle_action(socket, presentation, message, actor_opts(socket))

    {:noreply, assign(socket, :presentation, presentation)}
  end

  def handle_event("a2ui:message", _message, socket), do: {:noreply, socket}

  def handle_event("a2ui:open_surface", args, socket), do: Host.open_surface(args, socket)

  @impl true
  # A refresh is not an event, so the context is rebuilt here: rows a revoked
  # grant showed are not read again under it.
  def handle_info({:ash_a2ui_host, :refresh}, %{assigns: %{presentation: %{} = p}} = socket) do
    socket = LiveUserAuth.refresh_actor_context(socket)
    {socket, presentation} = Host.refresh(socket, p, actor_opts(socket))

    {:noreply,
     socket |> assign(presentation: presentation, refresh_scheduled?: false) |> read_now()}
  end

  def handle_info({:ash_a2ui_host, :refresh}, socket),
    do: {:noreply, assign(socket, :refresh_scheduled?, false)}

  def handle_info(:freshness_tick, socket) do
    Process.send_after(self(), :freshness_tick, @tick_ms)
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  # Anything else is a notification on the surface's topics: coalesce it.
  def handle_info(_notification, %{assigns: %{presentation: %{}}} = socket) do
    case Host.schedule_refresh(socket.assigns.refresh_scheduled?) do
      :scheduled -> {:noreply, assign(socket, :refresh_scheduled?, true)}
      :already_scheduled -> {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp read_now(socket) do
    now = DateTime.utc_now()
    assign(socket, read_at: now, now: now)
  end

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
            <.saved_status
              validity={@validity}
              freshness={SavedStatus.freshness(@read_at, @now)}
              read_at={@read_at}
            />
          </div>
          <div class="flex items-center gap-2">
            <.button navigate={~p"/app/agent"} size="sm" variant="ghost">
              <.icon name="hero-sparkles" class="size-4" /> Agent
            </.button>
            <.button
              :if={@presentation}
              id="reread"
              type="button"
              size="sm"
              variant="ghost"
              phx-click="reread"
            >
              <.icon name="hero-arrow-path" class="size-4" /> {gettext("Read again")}
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

  attr :validity, :atom, required: true
  attr :freshness, :atom, required: true
  attr :read_at, :any, required: true

  # Two badges, never one: whether the definition still resolves, and how old
  # the rows are (`AshEnterprise.Surfaces.SavedStatus`).
  defp saved_status(assigns) do
    ~H"""
    <div id="pinned-status" class="flex flex-wrap items-center gap-2 pt-1">
      <.badge id="pinned-validity" tone={validity_tone(@validity)} data-validity={@validity}>
        <.icon name={validity_icon(@validity)} class="size-3.5" />
        {validity_label(@validity)}
      </.badge>
      <.badge id="pinned-freshness" tone={freshness_tone(@freshness)} data-freshness={@freshness}>
        <.icon name={freshness_icon(@freshness)} class="size-3.5" />
        {freshness_label(@freshness, @read_at)}
      </.badge>
    </div>
    """
  end

  defp validity_tone(:valid), do: "green"
  defp validity_tone(:invalid), do: "red"
  defp validity_tone(_unknown), do: "neutral"

  defp validity_icon(:valid), do: "hero-check-circle-micro"
  defp validity_icon(:invalid), do: "hero-x-circle-micro"
  defp validity_icon(_unknown), do: "hero-question-mark-circle-micro"

  defp validity_label(:valid), do: gettext("Definition valid")
  defp validity_label(:invalid), do: gettext("Definition invalid")
  defp validity_label(_unknown), do: gettext("Definition not checked yet")

  defp freshness_tone(:fresh), do: "green"
  defp freshness_tone(:stale), do: "yellow"
  defp freshness_tone(_unknown), do: "neutral"

  defp freshness_icon(:fresh), do: "hero-clock-micro"
  defp freshness_icon(:stale), do: "hero-exclamation-triangle-micro"
  defp freshness_icon(_unknown), do: "hero-question-mark-circle-micro"

  defp freshness_label(:fresh, read_at),
    do: gettext("Data read at %{time}", time: LocalTime.time(read_at))

  defp freshness_label(:stale, read_at),
    do:
      gettext("Data read at %{time}, over %{minutes} minutes ago",
        time: LocalTime.time(read_at),
        minutes: div(SavedStatus.fresh_seconds(), 60)
      )

  defp freshness_label(_unknown, _read_at), do: gettext("Data freshness unknown")
end
