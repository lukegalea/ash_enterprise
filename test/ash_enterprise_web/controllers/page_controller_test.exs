defmodule AshEnterpriseWeb.PageControllerTest do
  use AshEnterpriseWeb.ConnCase

  test "GET / redirects to the operator hub", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/app/hub"
  end

  test "the hub's old address still lands on it", %{conn: conn} do
    conn = get(conn, "/app/demo")
    assert redirected_to(conn) == "/app/hub"
  end
end
