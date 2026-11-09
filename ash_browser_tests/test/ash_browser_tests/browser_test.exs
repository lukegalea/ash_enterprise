defmodule AshBrowserTests.BrowserTest do
  use AshBrowserTests.Case, async: true

  alias AshBrowserTests.Fixture.Endpoint

  describe "sign-in" do
    test "a session cookie reaches the LiveView session", %{conn: conn} do
      conn
      |> sign_in(%{"user" => "alice"}, Endpoint.session_options())
      |> visit("/whoami")
      |> assert_connected()
      |> assert_has("#whoami", text: "alice", timeout: 5_000)
    end

    test "without one the page is anonymous", %{conn: conn} do
      conn |> visit("/whoami") |> assert_connected() |> assert_has("#whoami", text: "nobody")
    end
  end

  describe "the composed tree" do
    setup %{conn: conn} do
      %{conn: conn |> visit("/widgets") |> assert_connected()}
    end

    test "deep_query reaches two shadow roots down, Playwright CSS selectors do not need to", %{
      conn: conn
    } do
      assert [%{"text" => "Hidden in shadow"}] = deep_query(conn, ".deep-text")
    end

    test "assert_deep waits for text and deep_click clicks across shadow roots", %{conn: conn} do
      conn
      |> assert_deep(".deep-text", text: "Hidden")
      |> deep_click("button", text: "Deep button")
      |> assert_deep(".deep-text", text: "Clicked")
    end

    test "assert_deep fails when nothing matches, and refute_deep fails when something does", %{
      conn: conn
    } do
      assert_raise ExUnit.AssertionError, ~r/no-such-element/, fn ->
        assert_deep(conn, ".no-such-element", timeout: 100)
      end

      assert_raise ExUnit.AssertionError, ~r/expected nothing/, fn ->
        refute_deep(conn, ".deep-text")
      end

      assert_raise ExUnit.AssertionError, ~r/no element matches/, fn ->
        deep_click(conn, "button", text: "No such button")
      end
    end
  end

  describe "failure capture" do
    test "a healthy page has no failures", %{conn: conn} do
      conn |> visit("/plain") |> assert_connected() |> assert_no_browser_failures()
    end

    @tag allow_browser_failures: true
    test "records a console error", %{conn: conn} do
      conn = conn |> visit("/console-error") |> assert_connected()

      assert_raise ExUnit.AssertionError, ~r/fixture console error/, fn ->
        assert_no_browser_failures(conn)
      end
    end

    @tag allow_browser_failures: true
    test "records an uncaught page error", %{conn: conn} do
      conn = conn |> visit("/page-error") |> assert_connected()

      eventually(fn ->
        assert Enum.any?(browser_failures(conn), &(&1.type == :page_error))
      end)
    end

    @tag allow_browser_failures: true
    test "records a 5xx from a background fetch", %{conn: conn} do
      conn = conn |> visit("/fetches-500") |> assert_connected()

      eventually(fn ->
        assert Enum.any?(browser_failures(conn), &(&1[:type] == :http_5xx and &1[:status] == 500))
      end)
    end

    test "take_browser_failures consumes expected failures so the test passes at exit", %{
      conn: conn
    } do
      conn = conn |> visit("/console-error") |> assert_connected()
      assert [_failure] = take_browser_failures(conn, ~r/fixture console error/)
      assert_no_browser_failures(conn)
    end

    @tag allow_browser_failures: true
    test ":allow names acceptable failures", %{conn: conn} do
      conn = conn |> visit("/console-error") |> assert_connected()
      assert_no_browser_failures(conn, allow: [~r/fixture console error/])
    end
  end

  defp eventually(fun, attempts \\ 50) do
    fun.()
  rescue
    error in ExUnit.AssertionError ->
      if attempts == 0 do
        reraise error, __STACKTRACE__
      else
        Process.sleep(100)
        eventually(fun, attempts - 1)
      end
  end
end
