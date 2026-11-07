defmodule AshEnterpriseWeb.SurfaceLive do
  @moduledoc """
  The thin surface pages, one per registry entry that names a `ui` and no
  `live` (`AshEnterprise.Surfaces.generated/0`).

  Each is an `AshA2ui.LiveRenderer` over the entry's UI module and nothing
  else: the signed-in actor and its tenant, the request locale, deep links,
  and the application shell (`AshEnterpriseWeb.A2uiLive.Chrome`). The module
  is named after the entry's key (`:business_units` becomes
  `AshEnterpriseWeb.SurfaceLive.BusinessUnits`), and the router routes it at
  the entry's `path` from the same list, so adding a thin surface is one
  registry entry.

  A page that needs more than this (a refresh banner, reports run on arrival,
  a diagram) is written by hand and declared `renderer: :specialist` in the
  registry; `AshEnterpriseWeb.SurfaceLiveTest` refuses a hand-written
  renderer that is not declared.

  `actor/1` and `tenant/1` are the renderer callbacks. The actor is the
  `current_user` that `AshEnterpriseWeb.Plugs.LoadActorContext` already
  attached its authorization context to, so every read the surface makes runs
  under the viewer's own policies, and the tenant is read back off that
  context.
  """

  alias AshEnterprise.Security.ActorContext

  @doc "The renderer's `actor_fn`: the signed-in user, with its resolved context."
  def actor(socket), do: socket.assigns[:current_user]

  @doc "The renderer's `tenant_fn`: the tenant of the signed-in user's context."
  def tenant(socket), do: ActorContext.tenant(socket.assigns[:current_user])

  for surface <- AshEnterprise.Surfaces.generated() do
    doc = "The #{surface.label} surface at `#{surface.path}`, generated from its registry entry."

    body =
      quote do
        @moduledoc unquote(doc)

        use AshA2ui.LiveRenderer,
          action_fn: &AshEnterpriseWeb.A2ui.Host.act/3,
          locale_fn: &AshEnterpriseWeb.Locale.live_locale/1,
          gettext_backend: {AshEnterpriseWeb.Gettext, "ash_a2ui"},
          ui: unquote(surface.ui),
          deep_link: true,
          actor_fn: &AshEnterpriseWeb.SurfaceLive.actor/1,
          tenant_fn: &AshEnterpriseWeb.SurfaceLive.tenant/1

        @impl true
        def render(assigns), do: AshEnterpriseWeb.A2uiLive.Chrome.page(assigns)
      end

    Module.create(surface.live, body, Macro.Env.location(__ENV__))
  end
end
