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
    <header class="navbar px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <a href="/" class="flex w-fit items-center gap-2">
          <img src={~p"/images/logo.svg"} width="36" />
          <span class="text-sm font-semibold">Ash Enterprise</span>
        </a>
      </div>
      <div class="flex-none">
        <ul class="flex flex-column px-1 space-x-2 items-center">
          <%!--
            Administration. These are A2UI surfaces derived from resource
            metadata, not hand-written screens -- see
            lib/ash_enterprise_web/a2ui/. Each is filtered by the signed-in
            actor's policies, so a user with no grants sees an empty table
            rather than a 403.
          --%>
          <li><a href="/agent" class="btn btn-ghost btn-sm">Helper</a></li>
          <li><a href="/app/users" class="btn btn-ghost btn-sm">Users</a></li>
          <li><a href="/app/teams" class="btn btn-ghost btn-sm">Teams</a></li>
          <li><a href="/app/roles" class="btn btn-ghost btn-sm">Roles</a></li>
          <li>
            <a href="/app/business-units" class="btn btn-ghost btn-sm">Business units</a>
          </li>
          <li>
            <a href="/app/legacy-users" class="btn btn-ghost btn-sm">Legacy users</a>
          </li>
          <%!-- Grouped rather than four more top-level buttons: the bar already carries six
                and wraps below about 1400px, which is narrower than the width the
                documentation screenshots are captured at. A wrapped nav would appear in
                every one of them. --%>
          <li>
            <details class="dropdown">
              <summary class="btn btn-ghost btn-sm">Workflow</summary>
              <ul class="dropdown-content menu z-10 w-52 rounded-box bg-base-100 p-2 shadow">
                <li><a href="/app/tasks">My tasks</a></li>
                <li><a href="/app/processes">Processes</a></li>
                <li><a href="/app/decisions">Decisions</a></li>
                <li><a href="/app/triggers">Triggers</a></li>
              </ul>
            </details>
          </li>
          <li><a href="/admin" class="btn btn-ghost btn-sm">Admin</a></li>
          <li>
            <.theme_toggle />
          </li>
          <li>
            <a href="https://phoenix.hexdocs.pm/overview.html" class="btn btn-primary">
              Get Started <span aria-hidden="true">&rarr;</span>
            </a>
          </li>
        </ul>
      </div>
    </header>

    <main class="px-4 py-20 sm:px-6 lg:px-8">
      <div class={["mx-auto space-y-4", @width]}>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
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
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
