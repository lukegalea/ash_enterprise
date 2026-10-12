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

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <%!-- Sticky header on the page colour, ruled off with the ink border.
          The nav is chunky pills that lift on hover and press on click, with
          one primary call to action at the end. --%>
    <header class="sticky top-0 z-40 border-b-2 border-border bg-background">
      <div class="flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3 sm:px-6 lg:px-8">
        <a href="/" class="flex w-fit items-center gap-2.5">
          <img src={~p"/images/logo.svg"} width="32" alt="" />
          <span class="font-display text-lg leading-none tracking-tight">Ash Enterprise</span>
          <span
            class="inline-block size-3 -rotate-12 rounded-[3px] border-2 border-border bg-yellow"
            aria-hidden="true"
          />
        </a>
        <nav class="ms-auto" aria-label="Main">
          <ul class="flex flex-wrap items-center gap-1.5">
            <%!--
              Administration. These are A2UI surfaces derived from resource
              metadata, not hand-written screens -- see
              lib/ash_enterprise_web/a2ui/. Each is filtered by the signed-in
              actor's policies, so a user with no grants sees an empty table
              rather than a 403.
            --%>
            <li><a href="/agent" class={nav_pill()}>Helper</a></li>
            <li><a href="/app/users" class={nav_pill()}>Users</a></li>
            <li><a href="/app/teams" class={nav_pill()}>Teams</a></li>
            <li><a href="/app/roles" class={nav_pill()}>Roles</a></li>
            <li>
              <a href="/app/business-units" class={nav_pill()}>Business units</a>
            </li>
            <li>
              <a href="/app/legacy-users" class={nav_pill()}>Legacy users</a>
            </li>
            <li>
              <a href="/app/directory" class={nav_pill()}>Directory</a>
            </li>
            <%!-- Grouped rather than four more top-level pills: the bar already carries
                  seven and wraps below about 1400px, which is narrower than the width
                  the documentation screenshots are captured at. --%>
            <li>
              <details class="group relative">
                <summary class={[nav_pill(), "list-none [&::-webkit-details-marker]:hidden"]}>
                  Workflow
                  <.icon
                    name="hero-chevron-down-micro"
                    class="size-4 transition-transform group-open:rotate-180"
                  />
                </summary>
                <ul class="absolute right-0 z-50 mt-2 w-52 rounded-base border-2 border-border bg-secondary-background p-1.5 shadow-shadow">
                  <li><a href="/app/tasks" class={menu_item()}>My tasks</a></li>
                  <li><a href="/app/processes" class={menu_item()}>Processes</a></li>
                  <li><a href="/app/decisions" class={menu_item()}>Decisions</a></li>
                  <li><a href="/app/triggers" class={menu_item()}>Triggers</a></li>
                </ul>
              </details>
            </li>
            <li><a href="/admin" class={nav_pill()}>Admin</a></li>
            <li class="ps-1">
              <.theme_toggle />
            </li>
            <li class="ps-1">
              <%!-- The demo hub replaces the generated "Get Started" CTA: this app's
                    front door is its own dashboard, not the framework's docs. --%>
              <.button href={~p"/app/demo"} variant="primary" size="sm">
                Demo hub <span aria-hidden="true">&rarr;</span>
              </.button>
            </li>
          </ul>
        </nav>
      </div>
    </header>

    <main class="px-4 py-10 sm:px-6 lg:px-8">
      <div class={["mx-auto space-y-4", @width]}>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  # Static strings so Tailwind's scanner sees every class.
  defp nav_pill do
    "inline-flex h-8 cursor-pointer items-center justify-center gap-1.5 whitespace-nowrap rounded-full border-2 border-border bg-secondary-background px-3 text-sm font-base text-foreground shadow-press transition-all hover:-translate-x-0.5 hover:-translate-y-0.5 hover:shadow-shadow focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background active:translate-x-0 active:translate-y-0 active:shadow-none"
  end

  defp menu_item do
    "block rounded-[3px] border-2 border-transparent px-3 py-1.5 text-sm font-base text-foreground hover:border-border hover:bg-main hover:text-main-foreground focus-visible:outline-hidden focus-visible:border-border focus-visible:bg-main focus-visible:text-main-foreground"
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
        aria-label="Use system theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4" />
      </button>

      <button
        class="relative flex w-1/3 cursor-pointer justify-center p-1.5 text-foreground [html[data-theme=light]:not([data-theme-source=system])_&]:text-on-vivid"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Use light theme"
      >
        <.icon name="hero-sun-micro" class="size-4" />
      </button>

      <button
        class="relative flex w-1/3 cursor-pointer justify-center p-1.5 text-foreground [html[data-theme=dark]:not([data-theme-source=system])_&]:text-on-vivid"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Use dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4" />
      </button>
    </div>
    """
  end
end
