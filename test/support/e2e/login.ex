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
  # Deliberately unspecced. Two attempts at a `@spec` here both made Dialyzer
  # worse, and the second explains the first: annotating `user` as `struct()`
  # means "any struct", which is wider than `AshAuthentication.Jwt
  # .token_for_user/1` accepts — so the body's success typing came out empty,
  # `as/2` had no local return, and every caller was reported as a call that
  # "will not succeed". A `@spec` that is vaguer than the code starves inference
  # rather than feeding it. Without one, the type flows from the fixture.
  def as(conn, %{user: user}) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    AshBrowserTests.Browser.sign_in(conn, %{"user_token" => token}, Endpoint.session_options())
  end
end
