defmodule AshEnterpriseWeb.DashboardLive do
  @moduledoc """
  The demo hub at `/app/demo`: one card per showcase surface of the POC.

  A strangler-pattern demo lives or dies on *two things being true at once* --
  the old vocabulary still working, the new one already working, over the same
  rows -- so the parties pair leads, full width and in the primary tone, and
  everything else is grouped behind it in the order a demo usually wants:
  model the process, see the domain, talk to the agents, drop to the console.

  The card chrome is deliberately the same daisyUI vocabulary every other page
  already speaks (`card`, `card-title`, `badge`, `btn`), because a hub that
  looked different from the pages it links to would read as a second product
  rather than a front door.
  """

  use AshEnterpriseWeb, :live_view

  require Ash.Query

  # Compile-time constant per env: the AshAdmin/clarity mounts in the router
  # read the same key, so the console card below agrees with what is actually
  # routed. False in test/prod, where the /admin route does not exist.
  @dev_routes? Application.compile_env(:ash_enterprise, :dev_routes, false)

  alias AshEnterprise.Security.ActorContext
  alias AshEnterpriseWeb.A2ui.Surfaces
  alias AshEnterpriseWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    # The same topics the canonical parties surface listens on, read off the
    # resource's publications rather than spelled out here -- one declaration,
    # no second spelling of the strings to drift. The dashboard is not a live
    # surface; it just refuses to show a stale count on its lead card.
    for topic <- Surfaces.topics(AshEnterpriseWeb.A2ui.CanonicalPartyUI) do
      Phoenix.PubSub.subscribe(AshEnterprise.PubSub, topic)
    end

    {:ok, assign(socket, party_count: count_parties(socket), dev_routes?: @dev_routes?)}
  end

  # A count, not a table: whatever arrives on a party topic, recount and move
  # on. Ash's PubSub notifier may deliver a Notification, a Broadcast or a bare
  # map depending on broadcast_type, so nothing is matched on -- the same
  # coalescing stance the helper agent's console takes.
  @impl true
  def handle_info(_notification, socket) do
    {:noreply, assign(socket, party_count: count_parties(socket))}
  end

  defp count_parties(socket) do
    actor = socket.assigns[:current_user]

    AshEnterprise.Contracts.Party
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.count(tenant: ActorContext.tenant(actor))
    |> case do
      {:ok, count} -> count
      {:error, _} -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={assigns[:current_scope]} width="max-w-7xl">
      <div class="space-y-6">
        <header class="space-y-1">
          <h1 class="text-2xl font-semibold">Demo dashboard</h1>
          <p class="max-w-3xl text-sm opacity-70">
            Every surface of the strangler-pattern proof of concept, one link away.
            The parties pair below is the demo itself; the rest is the supporting cast.
          </p>
        </header>

        <%!-- The lead card. Full width and primary-toned, because this pair is
              what the whole POC exists to demonstrate: the same companies,
              readable in both vocabularies, updating live from either side. --%>
        <.demo_card
          id="strangler-demo"
          icon="hero-arrows-right-left"
          title="The strangler demo"
          blurb="Two live tables over the same companies. The legacy one reads the old CLM
            schema through a compatibility view; the canonical one reads this application's
            own strangler resource. Open both, side by side, and make a write anywhere --
            each table rebuilds itself."
          primary
        >
          <:top_right>
            <span
              class="badge badge-success badge-outline badge-sm gap-1.5"
              title="Canonical party count right now -- refreshed whenever a write lands"
            >
              <span class="relative flex size-1.5">
                <span class="absolute inline-flex size-1.5 animate-ping rounded-full bg-success opacity-75" />
                <span class="relative inline-flex size-1.5 rounded-full bg-success" />
              </span>
              <%= if @party_count do %>
                {@party_count} parties · live
              <% else %>
                live
              <% end %>
            </span>
          </:top_right>
          <:actions>
            <.link navigate={~p"/app/legacy-parties"} class="btn btn-outline btn-sm">
              Legacy parties
            </.link>
            <.link navigate={~p"/app/canonical-parties"} class="btn btn-primary btn-sm">
              Canonical parties
            </.link>
          </:actions>
        </.demo_card>

        <div class="grid gap-4 md:grid-cols-2">
          <.demo_card
            id="process-modeller"
            icon="hero-square-3-stack-3d"
            title="Process modeller"
            blurb="The access-request flow drawn as BPMN and its risk gate as DMN --
              modelled in the browser with bpmn-js and dmn-js, executed by the platform.
              The catalogues list everything this tenant can run and where it came from."
            delay={75}
          >
            <:actions>
              <.link
                navigate={~p"/app/processes/access_request.grant/designer"}
                class="btn btn-primary btn-sm"
              >
                BPMN designer
              </.link>
              <.link
                navigate={~p"/app/decisions/access_request.risk/editor"}
                class="btn btn-outline btn-sm"
              >
                DMN risk editor
              </.link>
              <.link navigate={~p"/app/processes"} class="btn btn-ghost btn-xs">
                Process catalogue
              </.link>
              <.link navigate={~p"/app/decisions"} class="btn btn-ghost btn-xs">
                Decision catalogue
              </.link>
            </:actions>
          </.demo_card>

          <.demo_card
            id="domain-diagrams"
            icon="hero-map"
            title="Domain diagrams"
            blurb="The whole Ash domain as one entity-relationship diagram: every resource,
              relationship and attribute of both vocabularies on a single canvas."
            delay={150}
          >
            <:actions>
              <%!-- A plain anchor, not `<.link navigate>`: the Clarity surface sits behind
                    a `forward`, so Phoenix cannot verify paths beneath it. --%>
              <a
                href="/clarity/architect/application:ash-enterprise/ash-diagram-clarity-content-er-diagram"
                class="btn btn-primary btn-sm"
              >
                Ash domain ER diagram (Clarity viewer)
              </a>
            </:actions>
          </.demo_card>

          <.demo_card
            id="agents"
            icon="hero-chat-bubble-left-right"
            title="Agents"
            blurb="A natural-language console over each vocabulary. Reads render immediately
              as tables filtered by your own policies; writes wait for your approval."
            delay={225}
          >
            <:actions>
              <.link navigate={~p"/legacy/agent"} class="btn btn-outline btn-sm">
                Legacy helper
              </.link>
              <.link navigate={~p"/canonical/agent"} class="btn btn-outline btn-sm">
                Canonical helper
              </.link>
            </:actions>
          </.demo_card>

          <.demo_card
            id="console"
            icon="hero-squares-2x2"
            title="Console"
            blurb="AshAdmin over every resource -- the ground truth behind every card on
              this page, including users, roles and the workflow definitions."
            delay={300}
          >
            <:actions :if={@dev_routes?}>
              <%!-- `/admin` is mounted only when the `dev_routes` config is
                   on, so a verified `~p` sigil would warn at compile time in
                   every env where it is not (test, prod) -- which
                   `mix precommit` treats as an error. A plain href keeps the
                   route from going unconditional, and the guard keeps the
                   dead link out of those envs entirely. --%>
              <.link href="/admin" class="btn btn-primary btn-sm">
                Open the admin console
              </.link>
            </:actions>
          </.demo_card>
        </div>

        <%!-- The long tail, as chips rather than cards: these are "also exists"
              surfaces, and giving each a full card would bury the four above. --%>
        <.demo_card
          id="more-surfaces"
          icon="hero-table-cells"
          title="More surfaces"
          blurb="The rest of the read models -- live A2UI tables over both vocabularies,
            the projected directory, and your workflow inbox."
          delay={350}
        >
          <:actions>
            <.link navigate={~p"/app/legacy-users"} class="btn btn-outline btn-xs">
              Legacy users
            </.link>
            <.link navigate={~p"/app/legacy-contracts"} class="btn btn-outline btn-xs">
              Legacy contracts
            </.link>
            <.link navigate={~p"/app/canonical-contracts"} class="btn btn-outline btn-xs">
              Canonical contracts
            </.link>
            <.link navigate={~p"/app/canonical-commitments"} class="btn btn-outline btn-xs">
              Canonical commitments
            </.link>
            <.link navigate={~p"/app/directory"} class="btn btn-outline btn-xs">Directory</.link>
            <.link navigate={~p"/app/tasks"} class="btn btn-outline btn-xs">My tasks</.link>
          </:actions>
        </.demo_card>
      </div>
    </Layouts.app>
    """
  end

  # One card shape for every group: icon chip, title, one-line blurb, actions.
  # `primary` is the only tonal decision a caller makes -- the strangler card
  # earns it, everything else stays base-toned so the lead stays the lead.
  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :blurb, :string, required: true
  attr :primary, :boolean, default: false
  attr :delay, :integer, default: 0, doc: "entrance stagger, in milliseconds"

  slot :top_right, doc: "a badge or counter, right-aligned next to the title"
  slot :actions, required: true, doc: "the links out of this card"

  defp demo_card(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "card border bg-base-100",
        if(@primary, do: "border-primary/40", else: "border-base-300")
      ]}
      style={"transition-delay: #{@delay}ms"}
      phx-mounted={
        JS.transition(
          {"transition-all duration-500 ease-out", "opacity-0 translate-y-2",
           "opacity-100 translate-y-0"},
          time: 500
        )
      }
    >
      <div class="card-body gap-4">
        <div class="flex items-start justify-between gap-3">
          <h2 class="card-title flex items-center gap-3 text-base">
            <span class={[
              "grid size-9 shrink-0 place-items-center rounded-box border",
              if(
                @primary,
                do: "border-primary/30 bg-primary/10 text-primary",
                else: "border-base-300 bg-base-200 text-base-content/70"
              )
            ]}>
              <.icon name={@icon} class="size-5" />
            </span>
            {@title}
          </h2>

          {render_slot(@top_right)}
        </div>

        <p class="max-w-3xl text-sm opacity-70">{@blurb}</p>

        <div class="card-actions flex-wrap items-center pt-1">
          {render_slot(@actions)}
        </div>
      </div>
    </div>
    """
  end
end
