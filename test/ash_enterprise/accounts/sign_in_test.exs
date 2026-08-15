defmodule AshEnterprise.Accounts.SignInTest do
  @moduledoc """
  That a correct password actually signs a user in.

  This exists because of a failure that produced no error anywhere. The policy
  set every platform resource inherits is injected by `use`, so it is declared
  *before* anything the resource writes itself — and policies are evaluated in
  declaration order. A `bypass AshAuthenticationInteraction` written in the
  resource's own `policies` block therefore landed *after* the grant union, which
  forbids a nil actor and collapses a read to `filter false`.

  The result: `sign_in_with_password` skipped its query entirely, never reached
  the password check, and reported *"Email or password was incorrect"* for a
  correct password. Nothing raised, no test failed, and the log line that
  explained it (`skipped query run due to filter being false`) only appears at
  debug level.

  Sign-in is exercised here through the strategy rather than the LiveView so the
  assertion is about authorization, not about markup.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Accounts.User

  @password "test-password-1234"

  defp register!(email) do
    User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{email: email, password: @password, password_confirmation: @password},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp sign_in(email, password) do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    AshAuthentication.Strategy.action(strategy, :sign_in, %{
      "email" => email,
      "password" => password
    })
  end

  defp unique_email, do: "sign-in-#{System.unique_integer([:positive])}@example.com"

  test "a correct password signs the user in and issues a token" do
    email = unique_email()
    registered = register!(email)

    assert {:ok, signed_in} = sign_in(email, @password)
    assert signed_in.id == registered.id

    # The token is the actual product of signing in. Without it the LiveView has
    # nothing to exchange, so its absence would be the same bug in a new place.
    assert is_binary(signed_in.__metadata__.token)
  end

  test "a wrong password does not sign the user in" do
    email = unique_email()
    register!(email)

    assert {:error, _} = sign_in(email, "not-the-password")
  end

  test "an unknown email does not sign anyone in" do
    assert {:error, _} = sign_in(unique_email(), @password)
  end

  test "the authentication bypass precedes the inherited grant union" do
    # The bug was one of ordering, so assert on the order rather than only on the
    # behaviour it produces. Any policy evaluated before the bypass can forbid the
    # nil actor that every sign-in necessarily has.
    [first | _] = Ash.Policy.Info.policies(User)

    assert first.bypass?
    assert [{AshAuthentication.Checks.AshAuthenticationInteraction, _}] = first.condition
  end
end
