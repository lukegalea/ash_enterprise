defmodule AshEnterpriseWeb.PageController do
  use AshEnterpriseWeb, :controller

  # The app's root is not a landing page: it hands straight to the launcher at
  # /app. That route lives behind the signed-in live session, so this one
  # redirect is also what routes a signed-out visitor to /sign-in -- the
  # launcher's on_mount does the bouncing, not the root.
  def root(conn, _params), do: redirect(conn, to: ~p"/app")

  # The launcher's older addresses: /app/hub (the operator hub it replaced) and
  # /app/demo (the hub's address before that). Bookmarks and older docs still
  # point at both.
  def launcher(conn, _params), do: redirect(conn, to: ~p"/app")
end
