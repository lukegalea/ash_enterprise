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
  rather than a per-mount query.
  """

  defmodule Users do
    @moduledoc "A2UI surface for users."
    use AshA2ui.LiveRenderer,
      ui: AshEnterpriseWeb.A2ui.UserUI,
      actor_fn: &__MODULE__.actor/1,
      tenant_fn: &__MODULE__.tenant/1

    def actor(socket), do: socket.assigns[:current_user]

    def tenant(socket),
      do: socket.assigns[:current_user] && socket.assigns.current_user.organization_id
  end

  defmodule Roles do
    @moduledoc "A2UI surface for security roles."
    use AshA2ui.LiveRenderer,
      ui: AshEnterpriseWeb.A2ui.RoleUI,
      actor_fn: &__MODULE__.actor/1,
      tenant_fn: &__MODULE__.tenant/1

    def actor(socket), do: socket.assigns[:current_user]

    def tenant(socket),
      do: socket.assigns[:current_user] && socket.assigns.current_user.organization_id
  end

  defmodule Teams do
    @moduledoc "A2UI surface for teams."
    use AshA2ui.LiveRenderer,
      ui: AshEnterpriseWeb.A2ui.TeamUI,
      actor_fn: &__MODULE__.actor/1,
      tenant_fn: &__MODULE__.tenant/1

    def actor(socket), do: socket.assigns[:current_user]

    def tenant(socket),
      do: socket.assigns[:current_user] && socket.assigns.current_user.organization_id
  end

  defmodule BusinessUnits do
    @moduledoc "A2UI surface for the business-unit hierarchy."
    use AshA2ui.LiveRenderer,
      ui: AshEnterpriseWeb.A2ui.BusinessUnitUI,
      actor_fn: &__MODULE__.actor/1,
      tenant_fn: &__MODULE__.tenant/1

    def actor(socket), do: socket.assigns[:current_user]

    def tenant(socket),
      do: socket.assigns[:current_user] && socket.assigns.current_user.organization_id
  end
end
