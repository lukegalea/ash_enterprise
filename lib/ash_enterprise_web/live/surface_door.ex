defmodule AshEnterpriseWeb.SurfaceDoor do
  @moduledoc """
  The web half of the surface doors (`AshEnterprise.Surfaces.Doors`), and the
  one place a LiveView learns which registry surface it is.

  On mount it finds the registry entry for the LiveView being mounted (by
  module and live action), checks its door, and assigns:

    * `:surface` — the `AshEnterprise.Surfaces.Surface`, or `nil` for a page
      that is not a registry surface (the launcher, the helper, the canvas);
    * `:page` — what the app layout needs to draw its chrome:
      `%{surface:, nav:, as_of:}`, where `nav` is the registry groups the
      actor may open (the grouped menus) and `as_of` is when the page loaded
      (the header's as-of line). Pass it on: `<Layouts.app page={assigns[:page]}>`.

  A closed door halts the mount and sends the person to the launcher with a
  flash naming who the surface is for. Behind an open door the surface still
  reads as the actor; the door decides nothing the policies do not, it only
  explains an empty page before it happens. ACP checks the same predicate
  (`AshEnterprise.Acp.Commands`), so a surface closed here is closed there.

  Runs after `{AshEnterpriseWeb.LiveUserAuth, :live_user_required}`, which
  installs `:current_user` with its precomputed `ActorContext`.
  """

  use AshEnterpriseWeb, :verified_routes

  alias AshEnterprise.Surfaces
  alias AshEnterprise.Surfaces.Doors

  def on_mount(:default, _params, _session, socket) do
    actor = socket.assigns[:current_user]
    surface = Surfaces.by_live(socket.view, socket.assigns[:live_action])

    if is_nil(surface) or Surfaces.open?(surface, actor) do
      page = %{surface: surface, nav: Surfaces.grouped(actor), as_of: DateTime.utc_now()}
      {:cont, Phoenix.Component.assign(socket, surface: surface, page: page)}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(
         :error,
         "#{surface.label} is for #{Doors.audience(surface.door)}."
       )
       |> Phoenix.LiveView.redirect(to: ~p"/app")}
    end
  end
end
