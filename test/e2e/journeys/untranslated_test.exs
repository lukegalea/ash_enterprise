defmodule AshEnterpriseWeb.E2E.Journeys.UntranslatedTest do
  @moduledoc """
  The pseudo-locale run's check (`AshBrowserTests.Journeys.Untranslated`) in a
  real browser, in the pseudo-locale: a label nobody translated, in the page or
  inside a component's shadow root, fails with its text and where it was; the same
  label under a mask is not read; and the pseudo-locale answers every message
  accented.
  """

  use AshBrowserTests.Case, async: true

  alias AshBrowserTests.Browser
  alias AshBrowserTests.Journeys
  alias AshBrowserTests.Journeys.Untranslated
  alias AshEnterprise.Test.DailyFixtures
  alias AshEnterpriseWeb.E2E.Login

  @mask ~s([id$="-as-of"])

  setup context do
    admin = DailyFixtures.tenant!()

    conn =
      context.conn
      |> Login.as(admin)
      |> PhoenixTest.visit("/app/users")
      |> Browser.assert_connected()
      |> PhoenixTest.assert_has("html[lang=en-XA]")

    %{conn: conn}
  end

  @tag browser_context_opts: Journeys.framing("en-XA")
  test "the pseudo-locale answers a message accented", %{conn: conn} do
    PhoenixTest.assert_has(conn, "h1", text: "⟦Ûšéŕš")
  end

  @tag browser_context_opts: Journeys.framing("en-XA")
  test "a label nobody translated fails with its text and where it was", %{conn: conn} do
    probe(conn, ~s(<div id="probe"><span>Deliberately untranslated</span></div>))

    error =
      assert_raise ExUnit.AssertionError, fn ->
        Untranslated.assert_translated!(
          conn,
          "#probe",
          [@mask],
          [],
          "surface users, figure probe"
        )
      end

    assert error.message =~ "visible English in the pseudo-locale, on surface users, figure probe"
    assert error.message =~ ~s("Deliberately untranslated")
  end

  @tag browser_context_opts: Journeys.framing("en-XA")
  test "an untranslated label inside a shadow root fails too", %{conn: conn} do
    probe(
      conn,
      ~s(<div id="probe"></div>),
      "document.getElementById('probe').attachShadow({mode: 'open'}).innerHTML = '<button>Cancel</button>'"
    )

    error =
      assert_raise ExUnit.AssertionError, fn ->
        Untranslated.assert_translated!(conn, "#probe", [], [], "the probe")
      end

    assert error.message =~ ~s("Cancel")
  end

  @tag browser_context_opts: Journeys.framing("en-XA")
  test "an untranslated label under a mask, or named as data, does not fail", %{conn: conn} do
    probe(
      conn,
      ~s(<div id="probe"><span id="probe-as-of">As of Monday</span> <i>dana@example.test</i></div>)
    )

    assert :ok =
             Untranslated.assert_translated!(
               conn,
               "#probe",
               [@mask],
               ["dana@example.test"],
               "the probe"
             )
  end

  defp probe(conn, html, extra \\ "null") do
    parent = self()
    ref = make_ref()

    expression = """
    (() => {
      document.body.insertAdjacentHTML("beforeend", #{Jason.encode!(html)})
      #{extra}
      return true
    })()
    """

    PhoenixTest.Playwright.evaluate(conn, expression, &send(parent, {ref, &1}))

    receive do
      {^ref, true} -> :ok
    after
      5_000 -> flunk("the page did not take the probe")
    end
  end
end
