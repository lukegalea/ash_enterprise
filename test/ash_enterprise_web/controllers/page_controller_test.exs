defmodule AshEnterpriseWeb.PageControllerTest do
  use AshEnterpriseWeb.ConnCase

  test "GET / redirects to the launcher", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/app"
  end

  test "the operator hub's old addresses land on the launcher", %{conn: conn} do
    assert conn |> get("/app/hub") |> redirected_to() == "/app"
    assert build_conn() |> get("/app/demo") |> redirected_to() == "/app"
  end
end
