defmodule AshEnterpriseWeb.E2E.Journeys.FrenchContextTest do
  @moduledoc """
  A journey in French runs its personas in browser contexts whose locale is
  French (`AshBrowserTests.Journeys.framing/1`), signed in through the session
  cookie, never the form. This is what makes the French run French: the app
  answers in the context's language, read from its `Accept-Language`
  (`AshEnterpriseWeb.Locale`), for the dead render and for the LiveView it
  connects to.
  """

  use AshBrowserTests.Case, async: true

  alias AshBrowserTests.Browser
  alias AshEnterprise.Test.DailyFixtures
  alias AshEnterpriseWeb.E2E.Login

  @tag browser_context_opts: AshBrowserTests.Journeys.framing("fr")
  test "a French context signed in by cookie sees the users surface in French", context do
    admin = DailyFixtures.tenant!()

    context.conn
    |> Login.as(admin)
    |> PhoenixTest.visit("/app/users")
    |> Browser.assert_connected()
    |> PhoenixTest.assert_has("html[lang=fr]")
    |> PhoenixTest.assert_has("h1", text: "Utilisateurs")
    |> Browser.assert_deep("[data-a2ui-row-id] button, [data-a2ui-row-id] atlas-button",
      text: "Désactiver",
      timeout: 15_000
    )
  end

  @tag browser_context_opts: AshBrowserTests.Journeys.framing("en")
  test "the same page in an English context is in English", context do
    admin = DailyFixtures.tenant!()

    context.conn
    |> Login.as(admin)
    |> PhoenixTest.visit("/app/users")
    |> Browser.assert_connected()
    |> PhoenixTest.assert_has("html[lang=en]")
    |> PhoenixTest.assert_has("h1", text: "Users")
  end
end
