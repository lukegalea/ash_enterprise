defmodule AshEnterpriseWeb.DashboardLive do
  @moduledoc """
  The operator hub at `/app/hub`: the front door, one card per area an
  operator works in day to day.

  Ordered by how often each is reached for: the work waiting on you leads, full
  width and in the primary tone; then processes, compliance, the contract data,
  people and access, the agents; the developer console last, and only where its
  routes exist. The product name in the copy is `AshEnterprise.Brand`'s, so a
  deployment that renames itself is not contradicted by its own home page.

  The card chrome is deliberately the same design-system vocabulary every other
  page already speaks (`card/1`, `badge/1`, `button/1` from CoreComponents),
  because a hub that looked different from the pages it links to would read as
  a second product rather than a front door.
  """

  use AshEnterpriseWeb, :live_view

  # Compile-time constant per env: the AshAdmin/clarity mounts in the router
  # read the same key, so the console card below agrees with what is actually
  # routed. False in test/prod, where /admin, /clarity and /canvas do not exist.
  @dev_routes? Application.compile_env(:ash_enterprise, :dev_routes, false)

  alias AshEnterprise.Security.ActorContext
  alias AshEnterpriseWeb.A2ui.Surfaces
  alias AshEnterpriseWeb.ComplianceAuth
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

    actor = socket.assigns[:current_user]

    {:ok,
     assign(socket,
       page_title: "Operator hub",
       product_name: AshEnterprise.Brand.product_name(),
       email: actor && to_string(actor.email),
       compliance?: ComplianceAuth.authorized?(actor),
       party_count: count_parties(socket),
       dev_routes?: @dev_routes?
     )}
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
          <h1 class="font-display text-3xl tracking-tight">Operator hub</h1>
          <p class="max-w-3xl text-sm text-foreground/70">
            Everything you run in {@product_name}, one link away<span :if={@email}>
              — signed in as <span class="font-heading text-foreground">{@email}</span></span>.
          </p>
        </header>

        <%!-- The lead card. Full width and primary-toned, because the work
              waiting on you is why you opened the app. --%>
        <.hub_card
          id="your-work"
          icon="hero-inbox-stack"
          title="Your work"
          blurb="The tasks processes have routed to you, and the helper: ask for a change in
            plain words, review what it proposes, approve it or don't."
          primary
        >
          <:actions>
            <.button navigate={~p"/app/tasks"} variant="primary" size="sm">
              My tasks
            </.button>
            <.button navigate={~p"/agent"} size="sm">
              Ask the helper
            </.button>
          </:actions>
        </.hub_card>

        <div class="grid gap-4 md:grid-cols-2">
          <.hub_card
            id="process-modeller"
            icon="hero-square-3-stack-3d"
            title="Processes & decisions"
            blurb="What this tenant runs: BPMN processes, the DMN decisions they consult and
              the triggers that start them. Open any one to read, draft or publish it."
            delay={75}
          >
            <:actions>
              <.button navigate={~p"/app/processes"} variant="primary" size="sm">
                Processes
              </.button>
              <.button navigate={~p"/app/decisions"} size="sm">
                Decisions
              </.button>
              <.button navigate={~p"/app/triggers"} size="sm">
                Triggers
              </.button>
            </:actions>
          </.hub_card>

          <.hub_card
            :if={@compliance?}
            id="compliance"
            icon="hero-shield-check"
            title="Compliance"
            blurb="Findings and the evaluations behind them, and the rule sets, bundles,
              catalogs and profiles they are evaluated against."
            delay={150}
          >
            <:actions>
              <.button navigate={~p"/app/compliance/findings"} variant="primary" size="sm">
                Findings
              </.button>
              <.button navigate={~p"/app/compliance/evaluations"} size="sm">
                Evaluations
              </.button>
              <.button navigate={~p"/app/compliance/rule-sets"} variant="ghost" size="xs">
                Rule sets
              </.button>
              <.button navigate={~p"/app/compliance/bundles"} variant="ghost" size="xs">
                Bundles
              </.button>
              <.button navigate={~p"/app/compliance/catalogs"} variant="ghost" size="xs">
                Catalogs
              </.button>
              <.button navigate={~p"/app/compliance/profiles"} variant="ghost" size="xs">
                Profiles
              </.button>
            </:actions>
          </.hub_card>

          <.hub_card
            id="contracts"
            icon="hero-document-text"
            title="Contracts & parties"
            blurb="Parties, contracts and commitments, live: a write from either side —
              this app or the legacy system — shows up without a reload."
            delay={225}
          >
            <:top_right>
              <.badge
                tone="green"
                sticker
                title="Party count right now — refreshed whenever a write lands"
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
              <.button navigate={~p"/app/canonical-parties"} variant="primary" size="sm">
                Parties
              </.button>
              <.button navigate={~p"/app/canonical-contracts"} size="sm">
                Contracts
              </.button>
              <.button navigate={~p"/app/canonical-commitments"} size="sm">
                Commitments
              </.button>
              <.button navigate={~p"/app/legacy-parties"} variant="ghost" size="xs">
                Legacy parties
              </.button>
              <.button navigate={~p"/app/legacy-contracts"} variant="ghost" size="xs">
                Legacy contracts
              </.button>
            </:actions>
          </.hub_card>

          <.hub_card
            id="people"
            icon="hero-user-group"
            title="People & access"
            blurb="Who can sign in, the teams and business units they belong to, and the
              roles that decide what each of them sees."
            delay={300}
          >
            <:actions>
              <.button navigate={~p"/app/users"} variant="primary" size="sm">
                Users
              </.button>
              <.button navigate={~p"/app/teams"} size="sm">Teams</.button>
              <.button navigate={~p"/app/roles"} size="sm">Roles</.button>
              <.button navigate={~p"/app/business-units"} size="sm">
                Business units
              </.button>
              <.button navigate={~p"/app/directory"} variant="ghost" size="xs">
                Directory
              </.button>
              <.button navigate={~p"/app/legacy-users"} variant="ghost" size="xs">
                Legacy users
              </.button>
            </:actions>
          </.hub_card>

          <.hub_card
            id="agents"
            icon="hero-chat-bubble-left-right"
            title="Agents"
            blurb="A natural-language console over each vocabulary. Reads render immediately
              as tables filtered by your own policies; writes wait for your approval."
            delay={375}
          >
            <:actions>
              <.button navigate={~p"/agent"} variant="primary" size="sm">
                Helper
              </.button>
              <.button navigate={~p"/canonical/agent"} size="sm">
                Canonical helper
              </.button>
              <.button navigate={~p"/legacy/agent"} size="sm">
                Legacy helper
              </.button>
            </:actions>
          </.hub_card>

          <%!-- `/admin`, `/clarity`, `/canvas` and `/dev/dashboard` are mounted only when
                the `dev_routes` config is on, so a verified `~p` sigil would warn at
                compile time in every env where it is not (test, prod) -- which
                `mix precommit` treats as an error. Plain hrefs keep the routes from
                going unconditional, and the guard keeps the dead links out of those
                envs entirely. --%>
          <.hub_card
            :if={@dev_routes?}
            id="console"
            icon="hero-squares-2x2"
            title="Console"
            blurb="The ground truth under every card on this page: AshAdmin over every
              resource, the domain as diagrams and as a browsable graph, and the node's
              own telemetry."
            delay={450}
          >
            <:actions>
              <.button href="/admin" variant="primary" size="sm">
                Admin console
              </.button>
              <%!-- A plain anchor, not `<.link navigate>`: the Clarity surface sits behind
                    a `forward`, so Phoenix cannot verify paths beneath it. --%>
              <.button
                href="/clarity/architect/application:ash-enterprise/ash-diagram-clarity-content-er-diagram"
                size="sm"
              >
                Domain diagram
              </.button>
              <.button href="/canvas" size="sm">Canvas</.button>
              <.button href="/dev/dashboard" variant="ghost" size="xs">
                Live dashboard
              </.button>
            </:actions>
          </.hub_card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # One card shape for every group: icon chip, title, one-line blurb, actions.
  # `primary` is the only tonal decision a caller makes -- the lead card earns
  # the blue accent, everything else shares the yellow one so the lead stays
  # the lead.
  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :blurb, :string, required: true
  attr :primary, :boolean, default: false
  attr :delay, :integer, default: 0, doc: "entrance stagger, in milliseconds"

  slot :top_right, doc: "a badge or counter, right-aligned next to the title"
  slot :actions, required: true, doc: "the links out of this card"

  defp hub_card(assigns) do
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
