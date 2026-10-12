defmodule AshEnterpriseWeb.DashboardLive do
  @moduledoc """
  The demo hub at `/app/demo`: one card per showcase surface of the POC.

  A strangler-pattern demo lives or dies on *two things being true at once* --
  the old vocabulary still working, the new one already working, over the same
  rows -- so the parties pair leads, full width and in the primary tone, and
  everything else is grouped behind it in the order a demo usually wants:
  model the process, see the domain, talk to the agents, drop to the console.

  The card chrome is deliberately the same design-system vocabulary every other
  page already speaks (`card/1`, `badge/1`, `button/1` from CoreComponents),
  because a hub that looked different from the pages it links to would read as
  a second product rather than a front door.
  """

  use AshEnterpriseWeb, :live_view

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
    # Only on the connected mount: the dead render is a separate process that
    # exits straight away, so a subscription made there is never used.
    if connected?(socket) do
      for topic <- Surfaces.topics(AshEnterpriseWeb.A2ui.CanonicalPartyUI) do
        Phoenix.PubSub.subscribe(AshEnterprise.PubSub, topic)
      end
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
          <h1 class="font-display text-3xl tracking-tight">Demo dashboard</h1>
          <p class="max-w-3xl text-sm text-foreground/70">
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
          blurb="Two live tables over the same companies. The legacy one reads the old
            Contract Lifecycle Management schema through a compatibility view; the canonical
            one reads this application's own strangler resource. Open both, side by side,
            and make a write anywhere -- each table rebuilds itself."
          primary
        >
          <:top_right>
            <.badge
              tone="green"
              sticker
              title="Canonical party count right now -- refreshed whenever a write lands"
            >
              <span class="relative flex size-1.5">
                <span class="absolute inline-flex size-1.5 animate-ping rounded-full bg-on-vivid opacity-60" />
                <span class="relative inline-flex size-1.5 rounded-full bg-on-vivid" />
              </span>
              <%= if @party_count do %>
                {@party_count} parties · live
              <% else %>
                live
              <% end %>
            </.badge>
          </:top_right>
          <:actions>
            <.button navigate={~p"/app/legacy-parties"} size="sm">
              Legacy parties
            </.button>
            <.button navigate={~p"/app/canonical-parties"} variant="primary" size="sm">
              Canonical parties
            </.button>
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
              <.button
                navigate={~p"/app/processes/access_request.grant/designer"}
                variant="primary"
                size="sm"
              >
                BPMN designer
              </.button>
              <.button navigate={~p"/app/decisions/access_request.risk/editor"} size="sm">
                DMN risk editor
              </.button>
              <.button navigate={~p"/app/processes"} variant="ghost" size="xs">
                Process catalogue
              </.button>
              <.button navigate={~p"/app/decisions"} variant="ghost" size="xs">
                Decision catalogue
              </.button>
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
              <.button
                href="/clarity/architect/application:ash-enterprise/ash-diagram-clarity-content-er-diagram"
                variant="primary"
                size="sm"
              >
                Ash domain ER diagram (Clarity viewer)
              </.button>
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
              <.button navigate={~p"/legacy/agent"} size="sm">
                Legacy helper
              </.button>
              <.button navigate={~p"/canonical/agent"} size="sm">
                Canonical helper
              </.button>
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
              <.button href="/admin" variant="primary" size="sm">
                Open the admin console
              </.button>
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
            <.button navigate={~p"/app/legacy-users"} size="xs">
              Legacy users
            </.button>
            <.button navigate={~p"/app/legacy-contracts"} size="xs">
              Legacy contracts
            </.button>
            <.button navigate={~p"/app/canonical-contracts"} size="xs">
              Canonical contracts
            </.button>
            <.button navigate={~p"/app/canonical-commitments"} size="xs">
              Canonical commitments
            </.button>
            <.button navigate={~p"/app/directory"} size="xs">Directory</.button>
            <.button navigate={~p"/app/tasks"} size="xs">My tasks</.button>
          </:actions>
        </.demo_card>
      </div>
    </Layouts.app>
    """
  end

  # One card shape for every group: icon chip, title, one-line blurb, actions.
  # `primary` is the only tonal decision a caller makes -- the strangler card
  # earns the blue accent, everything else shares the yellow one so the lead
  # stays the lead.
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
    <.card
      id={@id}
      accent={if(@primary, do: "main", else: "yellow")}
      style={"transition-delay: #{@delay}ms"}
      phx-mounted={
        JS.transition(
          {"transition-all duration-500 ease-out", "opacity-0 translate-y-2",
           "opacity-100 translate-y-0"},
          time: 500
        )
      }
    >
      <div class="flex items-start justify-between gap-3">
        <h2 class="flex items-center gap-3 text-base font-heading">
          <span class={[
            "grid size-9 shrink-0 place-items-center rounded-base border-2 border-border text-on-vivid",
            if(@primary, do: "bg-main", else: "bg-yellow")
          ]}>
            <.icon name={@icon} class="size-5" />
          </span>
          {@title}
        </h2>

        {render_slot(@top_right)}
      </div>

      <p class="max-w-3xl text-sm text-foreground/75">{@blurb}</p>

      <div class="flex flex-wrap items-center gap-2.5 pt-1">
        {render_slot(@actions)}
      </div>
    </.card>
    """
  end
end
