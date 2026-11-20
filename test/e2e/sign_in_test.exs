defmodule AshEnterpriseWeb.E2E.SignInTest do
  @moduledoc """
  The real sign-in form, typed into by a real browser — the one test that does,
  rather than going through the session cookie like every surface test
  (`AshEnterpriseWeb.E2E.Login`).

  It is separate for a reason: if every surface test signed in through the form,
  a broken form would fail all of them at once and none of them would say that
  the form was the thing that broke.
  """

  use AshBrowserTests.Case, async: true

  alias AshEnterprise.Test.DailyFixtures

  test "a password sign-in lands signed in, and its submit is traced", %{
    conn: conn,
    test_key: key
  } do
    %{user: user} = DailyFixtures.tenant!()

    conn
    |> visit("/sign-in")
    |> assert_connected()
    |> fill_in("Email", with: to_string(user.email))
    |> fill_in("Password", with: "password1234")
    |> click_button("Sign in")
    |> refute_path("/sign-in", timeout: 15_000)
    |> assert_connected()

    # Server-side only. The natural assertion here is
    # `[browser_event(), handle_event()]` — the browser's span parenting the
    # server's handling of the submit — and that is what keystone asserts. This
    # application emits no browser spans at all (no `otel-browser` meta tag, no
    # tracer in `app.js`, no ingest route), so that chain would fail on an
    # absent span rather than on a broken trace.
    #
    # What is still worth asserting is the server half: the submit was handled,
    # and the user lookup it caused belongs to that same trace. Two matchers
    # because `assert_chain/3` asserts links — one span is not a chain, and the
    # link is the part that can break while both spans exist.
    assert_chain(key, [handle_event(), query()])
  end
end
