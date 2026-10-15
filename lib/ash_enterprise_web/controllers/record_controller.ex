defmodule AshEnterpriseWeb.RecordController do
  @moduledoc """
  The deep link: `/app/r/:surface/:id` opens one record on its registry
  surface — the address every reference link carries
  (`config :ash_a2ui, :open_surface_url`) and the one a person can share.

  It is a redirect, not a page. `AshEnterprise.Surfaces.Records.open/3`
  re-authorizes everything as the signed-in person — the surface's door, an
  authorized read of the record, the surface's own context selection — and
  the browser lands on the surface with the record selected
  (`/app/people?ctx[person]=<id>`), where the surface reads it again on mount.
  Anything they may not read gets one answer, "not found, or not yours", at
  the launcher. A signed-out visitor goes to sign-in.
  """

  use AshEnterpriseWeb, :controller

  alias AshEnterprise.Surfaces.Records

  def show(conn, %{"surface" => surface, "id" => id}) do
    case conn.assigns[:current_user] do
      nil ->
        redirect(conn, to: ~p"/sign-in")

      actor ->
        case Records.open(surface, id, actor) do
          {:ok, %{path: path}} ->
            redirect(conn, to: path)

          # A surface with no detail opens as itself.
          {:error, {:no_detail, surface}} ->
            redirect(conn, to: surface.path)

          {:error, error} ->
            conn
            |> put_flash(:error, Records.message(error))
            |> redirect(to: ~p"/app")
        end
    end
  end
end
