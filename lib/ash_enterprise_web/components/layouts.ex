defmodule AshEnterpriseWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use AshEnterpriseWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :width, :string,
    default: "max-w-2xl",
    doc: """
    Tailwind max-width for the content column. The prose default is far too
    narrow for a data table -- the A2UI surfaces pass `max-w-7xl` -- and the
    alternative to this attribute is those pages opting out of the chrome
    entirely, which is how they ended up with no navbar at all.
    """

  attr :page, :map,
    default: nil,
    doc: """
    The chrome `AshEnterpriseWeb.SurfaceDoor` assigns: `%{surface:, nav:, as_of:, actor:, context:}`.
    `nav` draws the grouped menus (only the surfaces whose door is open for the
    viewer); `surface` marks the current item and, when present, draws the page
    header -- the registry's label and blurb, and the as-of line. With an
    `actor`, the page gets the command palette and launcher (`AshEnterpriseWeb.Shell`).
    `context` draws the context band under the menus: tenant, identity and
    impersonation (`context_band/1`).
    """

  slot :toolbar, doc: "controls on the right of the page header (surface pages only)"
  slot :inner_block, required: true

  def app(assigns) do
    page = assigns.page || %{}

    assigns =
      assigns
      |> assign(:surface, page[:surface])
      |> assign(:as_of, page[:as_of])
      |> assign(:shell_actor, page[:actor])
      |> assign(:context, page[:context])
      |> assign(:menus, menus(page[:nav] || [], page[:surface]))

    ~H"""
    <%!-- Sticky header on the page colour, ruled off with the ink border.
          Today is pinned; every other surface sits in one of four menus
          derived from the registry (AshEnterprise.Surfaces), and the launcher
          is the one primary call to action. --%>
    <header class="sticky top-0 z-40 border-b-2 border-border bg-background">
      <div class="flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3 sm:px-6 lg:px-8">
        <a href="/app" class="flex w-fit items-center gap-2.5">
          <img src={~p"/images/logo.svg"} width="32" alt="" />
          <span class="font-display text-lg leading-none tracking-tight">
            {AshEnterprise.Brand.product_name()}
          </span>
          <span
            class="inline-block size-3 -rotate-12 rounded-[3px] border-2 border-border bg-yellow"
            aria-hidden="true"
          />
        </a>
        <nav class="ms-auto" aria-label={gettext("Main")}>
          <ul class="flex flex-wrap items-center gap-1.5">
            <li :if={@menus != []}>
              <a
                id="nav-today"
                href="/app/today"
                class={nav_pill(current?(@surface, :today))}
                aria-current={current?(@surface, :today) && "page"}
              >
                {gettext("Today")}
              </a>
            </li>
            <li :for={menu <- @menus}>
              <details class="group relative">
                <summary
                  id={"nav-#{menu.key}"}
                  class={[nav_pill(menu.current?), "list-none [&::-webkit-details-marker]:hidden"]}
                >
                  {AshEnterprise.Surfaces.translate(menu.label)}
                  <.icon
                    name="hero-chevron-down-micro"
                    class="size-4 transition-transform group-open:rotate-180"
                  />
                </summary>
                <ul class="absolute right-0 z-50 mt-2 max-h-[70vh] w-60 overflow-y-auto rounded-base border-2 border-border bg-secondary-background p-1.5 shadow-shadow">
                  <%= for {group, index} <- Enum.with_index(menu.groups) do %>
                    <li
                      :if={length(menu.groups) > 1}
                      id={"nav-group-#{group.key}"}
                      class={[
                        "px-3 pt-2 pb-1 text-xs font-heading uppercase tracking-wide text-foreground/70",
                        index > 0 && "mt-1.5 border-t-2 border-border"
                      ]}
                    >
                      {AshEnterprise.Surfaces.translate(group.label)}
                    </li>
                    <li :for={surface <- group.surfaces}>
                      <a
                        id={"nav-#{surface.key}"}
                        href={surface.path}
                        class={menu_item(current?(@surface, surface.key))}
                        aria-current={current?(@surface, surface.key) && "page"}
                      >
                        {AshEnterprise.Surfaces.translate(surface.label)}
                      </a>
                    </li>
                  <% end %>
                </ul>
              </details>
            </li>
            <li :if={@menus != []}><a href="/agent" class={nav_pill()}>{gettext("Helper")}</a></li>
            <%!-- /admin is mounted only under `dev_routes`; a link to it anywhere
                  else is a link to a 404. --%>
            <li :if={dev_routes?()}><a href="/admin" class={nav_pill()}>{gettext("Admin")}</a></li>
            <li class="ps-1">
              <.theme_toggle />
            </li>
            <li :if={@shell_actor} class="ps-1">
              <button
                type="button"
                id="nav-palette"
                class={nav_pill()}
                phx-click={AshA2ui.Shell.Component.open("palette")}
                title={gettext("Commands (ctrl+p)")}
              >
                <.icon name="hero-command-line-micro" class="size-4" />
                <span class="sr-only sm:not-sr-only">{gettext("Commands")}</span>
                <kbd class="hidden font-mono text-xs text-foreground/70 lg:inline">ctrl p</kbd>
              </button>
            </li>
            <li class="ps-1">
              <.button
                href="/app"
                variant="primary"
                size="sm"
                id="nav-launcher"
                title={gettext("All apps (ctrl+k)")}
              >
                <.icon name="hero-squares-2x2-micro" class="size-4" /> {gettext("All apps")}
              </.button>
            </li>
          </ul>
        </nav>
      </div>
      <.context_band :if={@context} context={@context} />
    </header>

    <%!-- The command palette (ctrl+p) and surface launcher (ctrl+k), on every
          page: AshA2ui.Shell.Component, fed by AshEnterpriseWeb.Shell from the
          same lists ACP serves. Signed-in pages only; it reads nothing until
          it opens. --%>
    <.live_component
      :if={@shell_actor}
      module={AshA2ui.Shell.Component}
      id="a2ui-shell"
      host={AshEnterpriseWeb.Shell}
      context={@shell_actor}
    />

    <main class="px-4 py-10 sm:px-6 lg:px-8">
      <div class={["mx-auto space-y-4", @width]}>
        <.page_header
          :if={@surface}
          id="page-header"
          title={AshEnterprise.Surfaces.translate(@surface.label)}
          blurb={AshEnterprise.Surfaces.translate(@surface.blurb)}
          icon={@surface.icon}
          as_of={@as_of}
          live={AshEnterprise.Surfaces.live?(@surface)}
        >
          <:toolbar>{render_slot(@toolbar)}</:toolbar>
        </.page_header>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  The context band: the tenant the person is working in, whom they act as,
  and, when they act on someone else's behalf, the operator really there.
  Drawn under the menus on every page whose chrome `AshEnterpriseWeb.SurfaceDoor`
  built; `context` is `AshEnterpriseWeb.SessionContext.for_actor/1`'s.

  An unreadable tenant reads "unknown", never blank, and impersonation is shown
  in the warning colour even when the operator cannot be named.
  """
  attr :context, :map, required: true

  def context_band(assigns) do
    ~H"""
    <dl
      id="context-band"
      class={[
        "flex flex-wrap items-center gap-x-5 gap-y-1 border-t-2 border-border px-4 py-1.5 text-xs sm:px-6 lg:px-8",
        @context.impersonator && "bg-yellow text-on-vivid"
      ]}
    >
      <div id="context-tenant" data-tenant={tenant_state(@context.tenant)} class="flex gap-1.5">
        <dt class="opacity-70">{gettext("Tenant")}</dt>
        <dd class="font-heading">{tenant_label(@context.tenant)}</dd>
      </div>
      <div id="context-identity" class="flex gap-1.5">
        <dt class="opacity-70">
          {if @context.impersonator, do: gettext("Acting as"), else: gettext("Signed in as")}
        </dt>
        <dd class="font-heading">{@context.identity || gettext("an actor with no email")}</dd>
      </div>
      <div
        :if={@context.impersonator}
        id="context-impersonation"
        data-impersonator={impersonator_state(@context.impersonator)}
        class="flex items-center gap-1.5"
      >
        <dt class="flex items-center gap-1">
          <.icon name="hero-eye-micro" class="size-4" />
          <span class="opacity-70">{gettext("Impersonated by")}</span>
        </dt>
        <dd class="font-heading">{impersonator_label(@context.impersonator)}</dd>
        <dd>{gettext("Both are recorded on everything done here.")}</dd>
      </div>
    </dl>
    """
  end

  defp tenant_state({:named, _name}), do: "named"
  defp tenant_state(state), do: to_string(state)

  defp tenant_label({:named, name}), do: name
  defp tenant_label(:none), do: gettext("none")
  defp tenant_label(_unknown), do: gettext("unknown")

  defp impersonator_state({:named, _email}), do: "named"
  defp impersonator_state(_unknown), do: "unknown"

  defp impersonator_label({:named, email}), do: email
  defp impersonator_label(_unknown), do: gettext("an operator who could not be named")

  # The nav's menus, from the registry groups the viewer may open: each menu
  # (`AshEnterprise.Surfaces.menus/0`) with its non-empty groups. Today is
  # pinned as its own pill, so it is left out of its menu.
  defp menus(nav, surface) do
    for {menu, label} <- AshEnterprise.Surfaces.menus(),
        groups = menu_groups(nav, menu),
        groups != [] do
      current? = Enum.any?(groups, fn group -> Enum.any?(group.surfaces, &(&1 == surface)) end)
      %{key: menu, label: label, groups: groups, current?: current?}
    end
  end

  defp menu_groups(nav, menu) do
    for %{menu: ^menu} = group <- nav,
        surfaces = Enum.reject(group.surfaces, &(&1.key == :today)),
        surfaces != [],
        do: %{group | surfaces: surfaces}
  end

  defp current?(%{key: key}, key), do: true
  defp current?(_surface, _key), do: false

  # The router mounts /admin under the same key. Read at runtime: a compile-time
  # constant here is a type warning in whichever env makes it always true.
  defp dev_routes?, do: Application.get_env(:ash_enterprise, :dev_routes, false)

  # Static strings so Tailwind's scanner sees every class. The current pill or item takes the
  # accent fill instead of the plain one, never both: with both in one class list the stylesheet's
  # order picks the winner, and the plain navy fill under the accent's black ink measures 1.3:1.
  defp nav_pill(current? \\ false) do
    [
      "inline-flex h-8 cursor-pointer items-center justify-center gap-1.5 whitespace-nowrap rounded-full border-2 border-border px-3 text-sm font-base shadow-press transition-all hover:-translate-x-0.5 hover:-translate-y-0.5 hover:shadow-shadow focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background active:translate-x-0 active:translate-y-0 active:shadow-none",
      if(current?,
        do: "bg-main text-main-foreground",
        else: "bg-secondary-background text-foreground"
      )
    ]
  end

  defp menu_item(current?) do
    [
      "block rounded-[3px] border-2 px-3 py-1.5 text-sm font-base hover:border-border hover:bg-main hover:text-main-foreground focus-visible:outline-hidden focus-visible:border-border focus-visible:bg-main focus-visible:text-main-foreground",
      if(current?,
        do: "border-border bg-main text-main-foreground",
        else: "border-transparent text-foreground"
      )
    ]
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <%!-- Phoenix's own flash region; page messages go through
            AshEnterpriseWeb.StatusComponents.status_message/1. --%>
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides the system / light / dark theme toggle. The palettes are the
  token sets in assets/css/neobrutalism.css; dark is the default.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <%!-- A segmented control: the blue block slides under the active choice,
          and the active icon switches to black ink so it reads on the blue.
          Dark is active when nothing is stored (data-theme-source="default"). --%>
    <div class="relative flex h-8 w-[6.5rem] flex-row items-center overflow-hidden rounded-full border-2 border-border bg-secondary-background shadow-press">
      <div class="absolute left-0 h-full w-1/3 rounded-full bg-main transition-[left] [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0" />

      <button
        class="relative flex w-1/3 cursor-pointer justify-center p-1.5 text-foreground [[data-theme-source=system]_&]:text-on-vivid"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label={gettext("Use system theme")}
      >
        <.icon name="hero-computer-desktop-micro" class="size-4" />
      </button>

      <button
        class="relative flex w-1/3 cursor-pointer justify-center p-1.5 text-foreground [html[data-theme=light]:not([data-theme-source=system])_&]:text-on-vivid"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label={gettext("Use light theme")}
      >
        <.icon name="hero-sun-micro" class="size-4" />
      </button>

      <button
        class="relative flex w-1/3 cursor-pointer justify-center p-1.5 text-foreground [html[data-theme=dark]:not([data-theme-source=system])_&]:text-on-vivid"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label={gettext("Use dark theme")}
      >
        <.icon name="hero-moon-micro" class="size-4" />
      </button>
    </div>
    """
  end
end
