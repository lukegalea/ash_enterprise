defmodule AshEnterpriseWeb.GuideLive do
  @moduledoc """
  The guide pages, one per guide in the registry (`AshEnterprise.Surfaces.guides/0`).

  Each is an `AshA2ui.LiveRenderer` with no UI module: its `ui` is the journey the
  guide shows, and its messages come from `AshEnterprise.Guides`, read in the
  request's locale. It answers no actions. The module is named after the journey
  (`:revoke_a_leavers_access` is `AshEnterpriseWeb.GuideLive.RevokeALeaversAccess`),
  and the router routes it at the entry's `path`, `/app/guide/<journey>`, from the
  same list, so the Shell, the launcher and ACP find a guide as they find any
  surface.
  """

  for guide <- AshEnterprise.Surfaces.guides() do
    doc = "The guide at `#{guide.path}`, generated from its registry entry."

    body =
      quote do
        @moduledoc unquote(doc)

        use AshA2ui.LiveRenderer,
          ui: unquote(guide.journey),
          surface_fn: &AshEnterprise.Guides.surface/2,
          action_fn: &AshEnterpriseWeb.A2ui.Host.act/3,
          locale_fn: &AshEnterpriseWeb.Locale.live_locale/1,
          actor_fn: &AshEnterpriseWeb.SurfaceLive.actor/1,
          tenant_fn: &AshEnterpriseWeb.SurfaceLive.tenant/1

        @impl true
        def render(assigns), do: AshEnterpriseWeb.A2uiLive.Chrome.page(assigns)
      end

    Module.create(guide.live, body, Macro.Env.location(__ENV__))
  end
end
