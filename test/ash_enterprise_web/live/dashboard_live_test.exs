defmodule AshEnterpriseWeb.DashboardLiveTest do
  @moduledoc """
  The operator hub: the front door every signed-in visitor lands on, and the
  one page whose copy carries the configured product name.
  """

  # async: false -- one test writes the product-name application env.
  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    seeded = AshEnterprise.Platform.Seeder.seed_legacy_estate()
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(seeded.user)

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session("user_token", token)

    %{conn: conn, seeded: seeded}
  end

  test "a signed-out visitor is sent to sign in" do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(build_conn(), ~p"/app/hub")
  end

  test "the hub links the work, the processes and the people", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/app/hub")

    assert html =~ "Operator hub"
    assert has_element?(view, "#your-work a[href='/app/tasks']")
    assert has_element?(view, "#your-work a[href='/agent']")
    assert has_element?(view, "#process-modeller a[href='/app/processes']")
    assert has_element?(view, "#people a[href='/app/users']")
    assert has_element?(view, "#contracts a[href='/app/canonical-parties']")
  end

  test "the header, the tab and the hub carry the configured product name", %{conn: conn} do
    previous = Application.fetch_env(:ash_enterprise, :product_name)
    Application.put_env(:ash_enterprise, :product_name, "Dogfood")

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ash_enterprise, :product_name, value)
        :error -> Application.delete_env(:ash_enterprise, :product_name)
      end
    end)

    html = conn |> get(~p"/app/hub") |> html_response(200)

    assert html =~ ~s(data-default="Dogfood")
    assert html =~ "Operator hub · Dogfood</title>"
    assert html =~ "Everything you run in Dogfood"
    refute html =~ "Ash Enterprise"
    refute html =~ "Phoenix Framework"
  end

  test "the sign-in banner carries the configured product name" do
    previous = Application.fetch_env(:ash_enterprise, :product_name)
    Application.put_env(:ash_enterprise, :product_name, "Dogfood")

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ash_enterprise, :product_name, value)
        :error -> Application.delete_env(:ash_enterprise, :product_name)
      end
    end)

    html = build_conn() |> get(~p"/sign-in") |> html_response(200)

    assert html =~ "Dogfood"
    refute html =~ "Ash Enterprise"
  end
end
