defmodule AshEnterpriseWeb.A2uiLive do
  @moduledoc """
  Renders the A2UI surfaces at `/app/:surface`.

  One LiveView per surface, each `use`-ing `AshA2ui.LiveRenderer`, which handles
  mount, render and the `a2ui:action` event. What we supply is the seam that
  matters: `actor_fn` and `tenant_fn`.

  Those two callbacks are what make the surface safe. `AshA2ui` resolves data by
  running the resource's own read actions with the actor we hand it, so every
  surface is filtered by the same policies as the admin UI and the API. The
  renderer does not need to know anything about authorization, and there is no
  way for it to bypass it — see `docs/manifesto/05-agents-are-users.md`.

  `AshEnterpriseWeb.Plugs.LoadActorContext` has already attached the resolved
  authorization context to `current_user`, so `actor_fn` is a plain assign read
  rather than a per-mount query, and `tenant_fn` reads the tenant back off that
  context. It does *not* read `current_user.organization_id`: `User` is
  `tenant?: false` and has no such attribute, so that access raises `KeyError` —
  which is what it did, on every surface, until the first time anyone signed in.
  """

  defmodule Chrome do
    @moduledoc """
    The application shell around a surface.

    `AshA2ui.LiveRenderer`'s default `render/1` returns the bare hook div, which
    is correct for a library — it has no idea what application it is inside —
    but it meant these pages rendered with no navbar, no container and content
    flush to the viewport edge, while the navbar elsewhere linked *to* them.

    The width is the reason this is a wrapper rather than a plain
    `<Layouts.app>` call: the default content column is `max-w-2xl`, sized for
    prose, and a data table inside it is unreadable.
    """

    use Phoenix.Component

    alias AshEnterpriseWeb.Layouts

    def page(assigns) do
      ~H"""
      <Layouts.app flash={@flash} width="max-w-7xl">
        {AshA2ui.LiveRenderer.surface_container(assigns)}
      </Layouts.app>
      """
    end
  end

  defmodule Users do
    @moduledoc "A2UI surface for users."
    use AshA2ui.LiveRenderer,
      ui: AshEnterpriseWeb.A2ui.UserUI,
      actor_fn: &__MODULE__.actor/1,
      tenant_fn: &__MODULE__.tenant/1

    alias AshEnterprise.Security.ActorContext
    alias AshEnterpriseWeb.A2uiLive.Chrome

    def actor(socket), do: socket.assigns[:current_user]

    def tenant(socket), do: ActorContext.tenant(socket.assigns[:current_user])

    def render(assigns), do: Chrome.page(assigns)
  end

  defmodule Roles do
    @moduledoc "A2UI surface for security roles."
    use AshA2ui.LiveRenderer,
      ui: AshEnterpriseWeb.A2ui.RoleUI,
      actor_fn: &__MODULE__.actor/1,
      tenant_fn: &__MODULE__.tenant/1

    alias AshEnterprise.Security.ActorContext
    alias AshEnterpriseWeb.A2uiLive.Chrome

    def actor(socket), do: socket.assigns[:current_user]

    def tenant(socket), do: ActorContext.tenant(socket.assigns[:current_user])

    def render(assigns), do: Chrome.page(assigns)
  end

  defmodule Teams do
    @moduledoc "A2UI surface for teams."
    use AshA2ui.LiveRenderer,
      ui: AshEnterpriseWeb.A2ui.TeamUI,
      actor_fn: &__MODULE__.actor/1,
      tenant_fn: &__MODULE__.tenant/1

    alias AshEnterprise.Security.ActorContext
    alias AshEnterpriseWeb.A2uiLive.Chrome

    def actor(socket), do: socket.assigns[:current_user]

    def tenant(socket), do: ActorContext.tenant(socket.assigns[:current_user])

    def render(assigns), do: Chrome.page(assigns)
  end

  defmodule LegacyUsers do
    @moduledoc """
    A2UI surface for the legacy read model, and the only one here that is live.

    The `:pubsub` option is what separates this from its four siblings. They are
    built once on mount and stay as they were until you reload; this one
    subscribes, and rebuilds its data model when something changes the underlying
    rows -- including when the change was made by an application that has never
    heard of Ash.

    ## The chain, and why every link is declared rather than inferred

        legacy INSERT
          -> AFTER trigger on legacy.users        (`notify? true` on the mapping)
          -> pg_notify, on commit only
          -> AshStrangler.Listener                (started in AshEnterprise.Application)
          -> Ash.Notifier.Notification
          -> `pub_sub` block on AshEnterprise.Legacy.User
          -> "legacy_users:created" on AshEnterprise.PubSub
          -> here

    The topics are listed by hand because `AshA2ui.LiveRenderer` does not
    introspect them -- it cannot know which publications a resource declares. So
    these three strings and the `pub_sub` block on the resource have to agree,
    and a typo here produces a surface that simply never updates, with nothing
    logged anywhere. That is the one genuinely fragile joint in the chain.

    ## What a refresh actually does

    `AshA2ui.LiveRenderer` debounces 150 ms and then rebuilds the whole data
    model through `AshA2ui.Info.build_data_model/2` -- carrying the viewer's
    current search, sort and page, so a background change does not throw away
    what they were looking at. The rebuild runs under `actor_fn`, which means the
    rows a viewer ends up seeing are the rows their own policies allow, not the
    rows the listener could read. The notification says *something changed*; it
    never says *what you may see*.

    ## The visual cue, and where the boundary is

    A banner above the surface announces the change and fades itself out. It is
    LiveView's own DOM, so `phx-mounted` works there exactly as it does anywhere
    else -- the element is genuinely added to the page when `@cue` becomes
    non-nil, which is what `phx-mounted` fires on.

    There is deliberately **no highlight on the changed row**, and that is a real
    limitation rather than a decision. The A2UI renderer owns everything inside
    `#ash-a2ui-surface`: `phx-update="ignore"` tells LiveView to keep out, and
    the components render into shadow DOM. So none of the three standard cue
    techniques reach a row:

      * `push_event` + `liveSocket.execJS` needs the element in the light DOM and
        carrying a `data-*` command LiveView rendered. LiveView renders no rows
        here, and `document.querySelectorAll` does not pierce a shadow root.
      * `phx-mounted` needs LiveView to render the element. Same reason.
      * A CSS keyframe on insertion needs the rule inside the shadow root. App
        stylesheets do not cross the boundary; only inherited custom properties
        (`--a2ui-*`) do.

    What a row-level highlight would actually take is written up under
    `## Visual cue` in docs/plans/ash-strangler-in-reference-app.md.
    """
    use AshA2ui.LiveRenderer,
      ui: AshEnterpriseWeb.A2ui.LegacyUserUI,
      actor_fn: &__MODULE__.actor/1,
      tenant_fn: &__MODULE__.tenant/1,
      pubsub: [
        module: AshEnterprise.PubSub,
        topics: [
          "legacy_users:created",
          "legacy_users:updated",
          "legacy_users:destroyed"
        ]
      ]

    alias AshEnterprise.Security.ActorContext
    alias AshEnterpriseWeb.Layouts
    alias Phoenix.LiveView.JS

    @cue_visible_ms 6_000

    def actor(socket), do: socket.assigns[:current_user]

    def tenant(socket), do: ActorContext.tenant(socket.assigns[:current_user])

    @impl true
    def mount(params, session, socket) do
      {:ok, socket} =
        AshA2ui.LiveRenderer.mount(__ash_a2ui_config__(), params, session, socket)

      {:ok, assign(socket, cue: nil, cue_ref: nil)}
    end

    # The renderer coalesces broadcasts into one debounced refresh and sends
    # itself `{:ash_a2ui, :refresh}` when the window closes. The cue is raised on
    # THAT rather than on the broadcast, so the banner and the rebuilt table
    # arrive together -- announcing an update 150 ms before it lands reads as a
    # bug even though nothing is wrong.
    #
    # Matching a message the renderer treats as internal is a real coupling, and
    # it is deliberately the degrading kind: if that tuple ever changes shape
    # this clause simply stops matching, the catch-all below still delegates, and
    # what is lost is the banner rather than the refresh.
    @impl true
    def handle_info({:ash_a2ui, :refresh} = message, socket) do
      {:noreply, socket} =
        AshA2ui.LiveRenderer.handle_notification(__ash_a2ui_config__(), message, socket)

      if socket.assigns.cue_ref, do: Process.cancel_timer(socket.assigns.cue_ref)
      ref = Process.send_after(self(), :clear_cue, @cue_visible_ms)

      {:noreply, assign(socket, cue: (socket.assigns.cue || 0) + 1, cue_ref: ref)}
    end

    def handle_info(:clear_cue, socket) do
      {:noreply, assign(socket, cue: nil, cue_ref: nil)}
    end

    def handle_info(message, socket) do
      AshA2ui.LiveRenderer.handle_notification(__ash_a2ui_config__(), message, socket)
    end

    @impl true
    def render(assigns) do
      ~H"""
      <Layouts.app flash={@flash} width="max-w-7xl">
        <%!--
          Keyed on @cue so the element is genuinely removed and re-added on each
          refresh -- which is what makes `phx-mounted` fire again for a second
          change rather than only the first.
        --%>
        <div :if={@cue} id={"legacy-cue-#{@cue}"} class="mb-4">
          <div
            class="flex items-center gap-2 rounded-lg border border-amber-400/60 bg-amber-50 px-4 py-2 text-sm text-amber-900 dark:border-amber-500/40 dark:bg-amber-950/60 dark:text-amber-100"
            phx-mounted={
              JS.transition(
                {"transition-all duration-500 ease-out", "opacity-0 -translate-y-1",
                 "opacity-100 translate-y-0"},
                time: 500
              )
            }
          >
            <span class="relative flex size-2">
              <span class="absolute inline-flex size-2 animate-ping rounded-full bg-amber-500 opacity-75" />
              <span class="relative inline-flex size-2 rounded-full bg-amber-500" />
            </span>
            <span>
              The legacy application changed these rows. The table below was rebuilt
              <span :if={@cue > 1} class="font-semibold">({@cue} updates)</span>
            </span>
          </div>
        </div>
        {AshA2ui.LiveRenderer.surface_container(assigns)}
      </Layouts.app>
      """
    end
  end

  defmodule BusinessUnits do
    @moduledoc "A2UI surface for the business-unit hierarchy."
    use AshA2ui.LiveRenderer,
      ui: AshEnterpriseWeb.A2ui.BusinessUnitUI,
      actor_fn: &__MODULE__.actor/1,
      tenant_fn: &__MODULE__.tenant/1

    alias AshEnterprise.Security.ActorContext
    alias AshEnterpriseWeb.A2uiLive.Chrome

    def actor(socket), do: socket.assigns[:current_user]

    def tenant(socket), do: ActorContext.tenant(socket.assigns[:current_user])

    def render(assigns), do: Chrome.page(assigns)
  end
end
