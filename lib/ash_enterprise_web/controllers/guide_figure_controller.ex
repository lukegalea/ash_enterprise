defmodule AshEnterpriseWeb.GuideFigureController do
  @moduledoc """
  `/app/guide/figures/:file`: one figure of a guide (`AshEnterprise.Guides.figure/1`),
  named `<file_sha256>.png` by the digest the journey lock records for it.

  Figures come from the seeded world a journey runs in, so they hold no tenant's data,
  but a guide is for people signed in and so are its figures: a signed-out visitor is
  sent to sign in. A name the lock does not approve is a `404`. The name is the content,
  so a figure is cached for good.
  """

  use AshEnterpriseWeb, :controller

  # Sobelow reads `@sobelow_skip` from the source AST; persisting it keeps
  # `--warnings-as-errors` from calling it unused (see Audit.Export).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  alias AshEnterprise.Guides

  def show(conn, %{"file" => file}) do
    case conn.assigns[:current_user] do
      nil -> redirect(conn, to: ~p"/sign-in")
      _actor -> serve(conn, file)
    end
  end

  # The body is a PNG the journey lock approved, found by its digest; the type is fixed.
  @sobelow_skip ["XSS.SendResp", "XSS.ContentType"]
  defp serve(conn, file) do
    with [digest] <- Regex.run(~r/\A([0-9a-f]{64})\.png\z/, file, capture: :all_but_first),
         {:ok, png} <- Guides.figure(digest) do
      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
      |> put_resp_content_type("image/png", nil)
      |> send_resp(200, png)
    else
      _ -> conn |> put_status(:not_found) |> text("Not found")
    end
  end
end
