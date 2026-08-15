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
