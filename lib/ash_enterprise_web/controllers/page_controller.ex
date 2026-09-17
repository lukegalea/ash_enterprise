defmodule AshEnterpriseWeb.PageController do
  use AshEnterpriseWeb, :controller

  # The app's root is no longer a generated landing page: it hands straight to
  # the demo dashboard at /app/demo. That route lives behind the signed-in live
  # session, so this one redirect is also what routes a signed-out visitor to
  # /sign-in -- the dashboard's on_mount does the bouncing, not the root.
  def root(conn, _params) do
    redirect(conn, to: ~p"/app/demo")
  end
end
