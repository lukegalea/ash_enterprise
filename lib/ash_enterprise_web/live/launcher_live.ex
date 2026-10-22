defmodule AshEnterpriseWeb.LauncherLive do
  @moduledoc """
  The launcher at `/app`: the front door, where sign-in lands.

  A grid of the key interfaces, rendered from the surface registry
  (`AshEnterprise.Surfaces`) — grouped as the registry groups them, and only
  the surfaces the viewer may open (`Surfaces.openable/1`: an open door, over
  a resource they may read). Nothing on this page names a surface by hand, so
  a surface added to the registry appears here (and in the nav, and over ACP)
  without anybody remembering to link it.

  It is the full-page form of the ctrl+k launcher (`AshEnterpriseWeb.Shell`):
  the same surfaces, and the filter box narrows them the way the launcher's
  input does (`AshA2ui.Shell.filter_surfaces/2`). Enter opens the first one
  left.

  Today leads, full width, with its live summary: the day's pulse
  (`AshEnterprise.Agents.Today.pulse/1`) and the morning brief's status. The
  same pulse puts a short signal on the cards it speaks for — approvals
  waiting, the next event, conversation counts, linked accounts. Every number
  is an ordinary read as the viewer, run off the LiveView process once the
  socket connects (the dead render shows the grid without them), and re-read
  when a brief or a task changes.

  Under the registry's groups, the viewer's own pinned apps ("My apps"):
  surfaces they composed in the agent chat and pinned
  (`AshEnterprise.Assistant.PinnedApp`, owner-only), read as them once the
  socket connects. Nobody else's launcher lists them.

  Replaces the operator hub (`/app/hub`, and `/app/demo` before it), which
  both redirect here.
  """

  use AshEnterpriseWeb, :live_view

  alias AshEnterprise.Agents.{MorningBrief, Today}
  alias AshEnterprise.Assistant.PinnedApp
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Surfaces
  alias AshEnterpriseWeb.Layouts
  alias AshEnterpriseWeb.Shell

  # Which pulse line speaks for which card.
  @signal_cards %{
    "Approvals" => :approvals,
    "Action items" => :action_items,
    "Next up" => :calendar,
    "Inbox" => :inbox,
    "Slack" => :slack
  }

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns[:current_user]
    groups = Surfaces.grouped(actor, &Surfaces.openable/1)

    socket =
      assign(socket,
        page_title: "Key interfaces",
        product_name: AshEnterprise.Brand.product_name(),
        email: actor && to_string(actor.email),
        today: Enum.find_value(groups, &Enum.find(&1.surfaces, fn s -> s.key == :today end)),
        groups:
          Enum.map(
            groups,
            &%{&1 | surfaces: Enum.reject(&1.surfaces, fn s -> s.key == :today end)}
          ),
        pulse: nil,
        brief: nil,
        signals: %{},
        pins: [],
        entries: Shell.surfaces(actor),
        filter: to_form(%{"q" => ""}, as: :launch),
        shown: nil,
        dev_routes?: Application.get_env(:ash_enterprise, :dev_routes, false)
      )

    if connected?(socket) do
      for topic <-
            Surfaces.topics(MorningBrief) ++ Surfaces.topics(HumanTask) ++ Surfaces.topics(Task) do
        Phoenix.PubSub.subscribe(AshEnterprise.PubSub, topic)
      end

      {:ok, socket |> load_signals() |> load_pins()}
    else
      {:ok, socket}
    end
  end

  # A brief or a task changed: re-read the summary. Whatever arrives on those
  # topics (a Notification, a Broadcast, a bare map) means the same thing.
  @impl true
  def handle_info(_notification, socket), do: {:noreply, load_signals(socket)}

  @impl true
  def handle_async(:signals, {:ok, {pulse, brief}}, socket) do
    signals =
      Enum.reduce(pulse, %{}, fn row, acc ->
        case signal_card(row.signal) do
          nil -> acc
          :accounts -> Map.update(acc, :accounts, 1, &(&1 + 1))
          key -> Map.put(acc, key, row.value)
        end
      end)
      |> Map.update(:accounts, nil, &"#{&1} linked")

    {:noreply, assign(socket, pulse: pulse, brief: brief, signals: signals)}
  end

  # A summary that could not be read is a quieter card, not a broken page.
  def handle_async(:signals, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async(:pins, {:ok, {:ok, pins}}, socket), do: {:noreply, assign(socket, :pins, pins)}
  def handle_async(:pins, _failed, socket), do: {:noreply, socket}

  # Narrow the grid as the launcher's input narrows its list. `shown` is the
  # matching surface keys, or nil for all of them.
  @impl true
  def handle_event("filter", %{"launch" => %{"q" => q}}, socket) do
    {:noreply, assign(socket, filter: to_form(%{"q" => q}, as: :launch), shown: shown(socket, q))}
  end

  def handle_event("launch", %{"launch" => %{"q" => q}}, socket) do
    case matches(socket, q) do
      [%{"id" => id} | _] ->
        {:noreply, push_navigate(socket, to: Surfaces.fetch!(id).path)}

      [] ->
        {:noreply, assign(socket, filter: to_form(%{"q" => q}, as: :launch), shown: MapSet.new())}
    end
  end

  defp matches(socket, q), do: AshA2ui.Shell.filter_surfaces(socket.assigns.entries, q)

  defp shown(socket, q) do
    if String.trim(q) == "",
      do: nil,
      else: socket |> matches(q) |> MapSet.new(&String.to_existing_atom(&1["id"]))
  end

  defp shown?(_surface, nil), do: true
  defp shown?(surface, shown), do: MapSet.member?(shown, surface.key)

  defp load_pins(socket) do
    actor = socket.assigns[:current_user]
    opts = [actor: actor, tenant: ActorContext.tenant(actor), authorize?: true]
    start_async(socket, :pins, fn -> PinnedApp.mine(opts) end)
  end

  defp load_signals(socket) do
    actor = socket.assigns[:current_user]
    opts = [actor: actor, tenant: ActorContext.tenant(actor)]

    start_async(socket, :signals, fn ->
      {:ok, pulse} = Today.pulse(opts)

      brief =
        case Today.latest_brief(opts) do
          {:ok, %MorningBrief{} = brief} -> brief
          _none -> nil
        end

      {pulse, brief}
    end)
  end

  defp signal_card(signal) do
    cond do
      Map.has_key?(@signal_cards, signal) -> @signal_cards[signal]
      String.ends_with?(signal, " sync") -> :accounts
      true -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={assigns[:page]} width="max-w-7xl">
      <div class="space-y-10">
        <header class="space-y-1">
          <h1 class="font-display text-3xl tracking-tight">Key interfaces</h1>
          <p class="max-w-3xl text-sm text-foreground/70">
            Everything you run in {@product_name}, one link away<span :if={@email}>
              — signed in as <span class="font-heading text-foreground">{@email}</span></span>.
          </p>
          <.form
            for={@filter}
            id="launch-filter"
            phx-change="filter"
            phx-submit="launch"
            class="max-w-md pt-3"
          >
            <.input
              field={@filter[:q]}
              type="search"
              label="Filter your apps"
              placeholder="Calendar, lineage, time travel…"
              autocomplete="off"
              phx-debounce="100"
            />
          </.form>
          <p class="text-xs text-foreground/60">
            From any page, <kbd class="font-mono">ctrl k</kbd>
            opens this list and <kbd class="font-mono">ctrl p</kbd>
            runs a command or asks the agent.
          </p>
        </header>

        <%!-- The lead: Today, with the day's pulse. Full width and in the
              primary tone, because the day is why you opened the app. --%>
        <.link
          :if={@today && shown?(@today, @shown)}
          id="launch-today"
          navigate={@today.path}
          class="group block rounded-base focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background"
        >
          <.card accent="main" class="transition-transform group-hover:-translate-y-0.5">
            <div class="flex flex-wrap items-start justify-between gap-3">
              <h2 class="flex items-center gap-3 text-xl font-heading">
                <span class="grid size-10 shrink-0 place-items-center rounded-base border-2 border-border bg-main text-on-vivid">
                  <.icon name={@today.icon} class="size-5" />
                </span>
                {@today.label}
              </h2>
              <.badge :if={@brief} id="launch-brief" status={@brief.status} sticker>
                Morning brief · {Today.brief_status(@brief.status)}
              </.badge>
              <.badge :if={@pulse && !@brief} id="launch-brief" tone="yellow" sticker>
                No morning brief yet
              </.badge>
            </div>
            <p class="max-w-3xl text-sm text-foreground/75">{@today.blurb}</p>
            <dl
              :if={@pulse}
              id="launch-pulse"
              class="grid gap-x-6 gap-y-1.5 pt-1 text-sm sm:grid-cols-2 lg:grid-cols-3"
            >
              <div :for={row <- @pulse} class="flex min-w-0 gap-2">
                <dt class="shrink-0 font-heading">{row.signal}</dt>
                <dd class="truncate text-foreground/75">{row.value}</dd>
              </div>
            </dl>
            <p :if={!@pulse} class="text-sm text-foreground/60">Reading your day…</p>
          </.card>
        </.link>

        <section
          :for={group <- @groups}
          :if={Enum.any?(group.surfaces, &shown?(&1, @shown))}
          id={"launch-group-#{group.key}"}
          class="space-y-3"
        >
          <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
            <h2 class="font-heading text-lg">{group.label}</h2>
            <p class="text-sm text-foreground/60">{group.blurb}</p>
          </div>
          <ul class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            <li :for={surface <- group.surfaces} :if={shown?(surface, @shown)}>
              <.link
                id={"launch-#{surface.key}"}
                navigate={surface.path}
                class="group block h-full rounded-base focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background"
              >
                <.card
                  accent={accent(group.key)}
                  class="h-full transition-transform group-hover:-translate-y-0.5"
                >
                  <div class="flex items-start justify-between gap-3">
                    <h3 class="flex items-center gap-2.5 font-heading">
                      <span class="grid size-8 shrink-0 place-items-center rounded-base border-2 border-border bg-background">
                        <.icon name={surface.icon} class="size-4" />
                      </span>
                      {surface.label}
                    </h3>
                    <.badge :if={@signals[surface.key]} id={"launch-#{surface.key}-signal"}>
                      {@signals[surface.key]}
                    </.badge>
                  </div>
                  <p class="text-sm text-foreground/75">{surface.blurb}</p>
                </.card>
              </.link>
            </li>
          </ul>
        </section>

        <section :if={@pins != []} id="launch-group-mine" class="space-y-3">
          <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
            <h2 class="font-heading text-lg">My apps</h2>
            <p class="text-sm text-foreground/60">
              Views you composed in the agent chat and pinned. Only you see them.
            </p>
          </div>
          <ul class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            <li :for={pin <- @pins}>
              <.link
                id={"launch-mine-#{pin.id}"}
                navigate={~p"/app/mine/#{pin.id}"}
                class="group block h-full rounded-base focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background"
              >
                <.card accent="main" class="h-full transition-transform group-hover:-translate-y-0.5">
                  <h3 class="flex items-center gap-2.5 font-heading">
                    <span class="grid size-8 shrink-0 place-items-center rounded-base border-2 border-border bg-background">
                      <.icon name={pin_icon(pin.display)} class="size-4" />
                    </span>
                    {pin.title}
                  </h3>
                  <p class="text-sm text-foreground/75">Pinned from the agent chat.</p>
                </.card>
              </.link>
            </li>
          </ul>
        </section>

        <.empty_state :if={@shown && MapSet.size(@shown) == 0} icon="hero-magnifying-glass">
          <span id="launch-no-match">No app matches “{@filter[:q].value}”.</span>
        </.empty_state>

        <.empty_state :if={!@today and @groups == []} icon="hero-lock-closed">
          Nothing is open to you yet. An administrator grants access by role.
        </.empty_state>

        <%!-- Not registry surfaces: the conversational consoles, and (only where
              its routes exist) the developer console. Plain hrefs for the dev
              routes, which a verified `~p` would warn about in test and prod. --%>
        <section id="launch-more" class="space-y-3 border-t-2 border-border pt-6">
          <h2 class="font-heading text-lg">Helpers</h2>
          <div class="flex flex-wrap items-center gap-2.5">
            <.button navigate={~p"/agent"} variant="primary" size="sm">Helper</.button>
            <.button navigate={~p"/legacy/agent"} size="sm">Legacy helper</.button>
            <%= if @dev_routes? do %>
              <span class="ms-2 text-xs font-heading uppercase tracking-wide text-foreground/60">
                Console
              </span>
              <.button href="/admin" variant="ghost" size="xs">Admin</.button>
              <.button
                href="/clarity/architect/application:ash-enterprise/ash-diagram-clarity-content-er-diagram"
                variant="ghost"
                size="xs"
              >
                Domain diagram
              </.button>
              <.button href="/canvas" variant="ghost" size="xs">Canvas</.button>
              <.button href="/dev/dashboard" variant="ghost" size="xs">Live dashboard</.button>
            <% end %>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp pin_icon(:calendar), do: "hero-calendar-days"
  defp pin_icon(:board), do: "hero-view-columns"
  defp pin_icon(_table), do: "hero-table-cells"

  # One accent per group, so a group reads as a group across the grid.
  defp accent(:day), do: "main"
  defp accent(:operator), do: "orange"
  defp accent(:processes), do: "violet"
  defp accent(:compliance), do: "red"
  defp accent(:org), do: "green"
  defp accent(:data), do: "cyan"
  defp accent(:legacy), do: "pink"
  defp accent(_group), do: nil
end
