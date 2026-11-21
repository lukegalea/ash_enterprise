defmodule AshEnterpriseWeb.E2E.Login do
  @moduledoc """
  Signs a browser test in without driving the sign-in form: the actor's token
  goes into the signed session cookie, where `ash_authentication`'s live
  sessions read it.

  Every surface test needs a signed-in browser, and going through the form each
  time would make each of them a test of the form as well — so when the form
  broke, every surface would fail and none of them would say why. The form is
  worth exactly one test of its own.
  """

  alias AshEnterpriseWeb.Endpoint

  @doc "`conn`, signed in as `ctx.user` (an `AshEnterprise.Test.DailyFixtures` context)."
  # `required(:user) => struct()` rather than `%{user: struct()}`: the latter is
  # a *closed* map type meaning "exactly this one key", and a fixture context
  # carries five. Dialyzer caught it as "the function call as will not succeed"
  # — correctly, since no caller could ever satisfy the narrower type.
  @spec as(struct(), %{required(:user) => struct()}) :: struct()
  def as(conn, %{user: user}) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    AshBrowserTests.Browser.sign_in(conn, %{"user_token" => token}, Endpoint.session_options())
  end
end
