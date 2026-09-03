defmodule AshEnterpriseWeb.PageControllerTest do
  use AshEnterpriseWeb.ConnCase

  test "GET / redirects to the demo dashboard", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/app/demo"
  end
end
