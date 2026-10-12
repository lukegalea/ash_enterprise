defmodule AshEnterpriseWeb.PageController do
  use AshEnterpriseWeb, :controller

  # The app's root is no longer a generated landing page: it hands straight to
  # the operator hub at /app/hub. That route lives behind the signed-in live
  # session, so this one redirect is also what routes a signed-out visitor to
  # /sign-in -- the hub's on_mount does the bouncing, not the root.
  def root(conn, _params) do
    redirect(conn, to: ~p"/app/hub")
  end

  # The hub's old address, from when it was the demo dashboard. Bookmarks and
  # links in older docs still point here.
  def legacy_hub(conn, _params) do
    redirect(conn, to: ~p"/app/hub")
  end
end
