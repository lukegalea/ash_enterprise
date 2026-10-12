defmodule AshEnterpriseWeb.LauncherLiveTest do
  @moduledoc """
  The launcher at `/app`: the front door every signed-in visitor lands on,
  rendered from the surface registry — grouped, door-filtered, Today leading
  with its live summary — and the one page whose copy carries the configured
  product name.
  """

  # async: false -- one test writes the product-name application env.
  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AshEnterprise.Test.DailyFixtures

  alias AshEnterprise.Surfaces

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  setup %{conn: conn} do
    ctx = tenant!()
    %{conn: sign_in(conn, ctx.user), ctx: ctx}
  end

  test "a signed-out visitor is sent to sign in" do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(build_conn(), ~p"/app")
  end

  test "every surface the viewer may open is a card, grouped as the registry groups it",
       %{conn: conn, ctx: ctx} do
    {:ok, view, html} = live(conn, ~p"/app")

    assert html =~ "Key interfaces"
    assert has_element?(view, "#launch-today[href='/app/today']")

    for surface <- Surfaces.visible(ctx.actor), surface.key != :today do
      assert has_element?(view, "#launch-group-#{surface.group} #launch-#{surface.key}"),
             "#{surface.key} is missing from the launcher"
    end

    # An administrator without the operator's grant: the erasure door is shut,
    # so its card is absent rather than a link to a redirect.
    refute has_element?(view, "#launch-erasure")
    refute has_element?(view, "#nav-erasure")
  end

  test "Today leads with the day's pulse, and the cards carry their signals",
       %{conn: conn, ctx: ctx} do
    brief!(ctx)

    {:ok, view, _html} = live(conn, ~p"/app")
    render_async(view, 5_000)

    assert has_element?(view, "#launch-pulse", "Approvals")
    assert has_element?(view, "#launch-brief", "waiting for your approval")
    assert has_element?(view, "#launch-approvals-signal", "1 waiting")
  end

  test "the operator's cards appear behind the operator's grant" do
    operator = tenant!(operator?: true)
    {:ok, view, _html} = live(sign_in(build_conn(), operator.user), ~p"/app")

    assert has_element?(view, "#launch-group-operator #launch-erasure")
  end

  test "the header, the tab and the launcher carry the configured product name",
       %{conn: conn} do
    previous = Application.fetch_env(:ash_enterprise, :product_name)
    Application.put_env(:ash_enterprise, :product_name, "Dogfood")

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ash_enterprise, :product_name, value)
        :error -> Application.delete_env(:ash_enterprise, :product_name)
      end
    end)

    html = conn |> get(~p"/app") |> html_response(200)

    assert html =~ ~s(data-default="Dogfood")
    assert html =~ "Key interfaces · Dogfood</title>"
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
