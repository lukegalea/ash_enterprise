defmodule AshEnterpriseWeb.SessionBoundsTest do
  @moduledoc """
  A browser session is bounded three ways by one lifetime (`Accounts.TokenPolicy`,
  8 hours): the session token expires, the session cookie that carries it expires with
  it, and a LiveView connected before the token expired stops acting when it does.
  """

  use AshEnterpriseWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias AshEnterprise.Accounts.TokenPolicy
  alias AshEnterprise.Platform.Seeder
  alias AshEnterpriseWeb.{Endpoint, LiveUserAuth}

  setup do
    n = System.unique_integer([:positive])
    %{user: user} = Seeder.seed_tenant(name: "Bounds #{n}", unique_name: "bounds-#{n}")
    %{user: user}
  end

  test "the session cookie expires with the session token", %{conn: conn} do
    assert Endpoint.session_options()[:max_age] == TokenPolicy.seconds()
    assert TokenPolicy.seconds() == 8 * 3600

    conn = get(conn, ~p"/sign-in")
    assert %{max_age: max_age} = conn.resp_cookies["_ash_enterprise_key"]
    assert max_age == TokenPolicy.seconds()
  end

  test "a session with no token, or an unreadable one, has no expiry to act on" do
    assert LiveUserAuth.session_expiry(%{}) == nil
    assert LiveUserAuth.session_expiry(%{"user_token" => "not-a-jwt"}) == nil
    refute LiveUserAuth.expired?(nil, System.os_time(:second))
  end

  test "an expiry is reached at its own second, not before" do
    assert LiveUserAuth.expired?(100, 100)
    assert LiveUserAuth.expired?(100, 101)
    refute LiveUserAuth.expired?(100, 99)
  end

  test "a live view connected before the token expired stops acting after it",
       %{conn: conn, user: user} do
    # A token that lives two seconds, issued the way sign-in issues one.
    {:ok, token, claims} =
      AshAuthentication.Jwt.token_for_user(user, %{}, token_lifetime: {2, :seconds})

    conn = conn |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_session("user_token", token)
    {:ok, view, _html} = live(conn, ~p"/app")
    monitor = Process.monitor(view.pid)

    assert LiveUserAuth.session_expiry(%{"user_token" => token}) == claims["exp"]

    # No sleep: the view's own timer redirects it at the token's expiry.
    assert {"/sign-in", flash} = assert_redirect(view, 5_000)
    assert flash["error"] =~ "expired"
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 1_000
  end
end
