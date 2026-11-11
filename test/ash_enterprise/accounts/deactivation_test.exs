defmodule AshEnterprise.Accounts.DeactivationTest do
  @moduledoc """
  A deactivated user (the platform lifecycle's `:inactive`) is out of every door:
  password sign-in, an existing session or bearer token, the sign-in token
  exchange and password reset. Deactivating also revokes the tokens already
  issued, so reactivating a user does not bring a stolen one back to life.

  Each door is asserted against an active control first, so a refusal here is
  the lifecycle's doing and not a broken fixture.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Accounts
  alias AshEnterprise.Accounts.User

  @password "test-password-1234"

  defp register! do
    email = "deact-#{System.unique_integer([:positive])}@example.test"

    User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{email: email, password: @password, password_confirmation: @password},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp sign_in(user, password \\ @password) do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    AshAuthentication.Strategy.action(strategy, :sign_in, %{
      "email" => to_string(user.email),
      "password" => password
    })
  end

  defp deactivate!(user) do
    user
    |> Ash.Changeset.for_update(:deactivate, %{}, authorize?: false)
    |> Ash.update!()
  end

  defp activate!(user) do
    user
    |> Ash.Changeset.for_update(:activate, %{}, authorize?: false)
    |> Ash.update!()
  end

  defp bearer_user(token) do
    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> AshAuthentication.Plug.Helpers.retrieve_from_bearer(:ash_enterprise)

    conn.assigns[:current_user]
  end

  describe "password sign-in" do
    test "an active user signs in" do
      user = register!()
      assert {:ok, _} = sign_in(user)
    end

    test "a deactivated user with the right password does not" do
      user = register!() |> deactivate!()
      assert {:error, _} = sign_in(user)
    end

    test "a reactivated user signs in again" do
      user = register!() |> deactivate!() |> activate!()
      assert {:ok, _} = sign_in(user)
    end
  end

  describe "tokens issued before deactivation" do
    test "a bearer token stops authenticating" do
      user = register!()
      {:ok, signed_in} = sign_in(user)
      token = signed_in.__metadata__.token

      assert bearer_user(token).id == user.id

      deactivate!(user)
      assert bearer_user(token) == nil
    end

    test "reactivating does not bring an old token back" do
      user = register!()
      {:ok, signed_in} = sign_in(user)
      token = signed_in.__metadata__.token

      user |> deactivate!() |> activate!()

      assert bearer_user(token) == nil
      assert {:ok, again} = sign_in(user)
      assert bearer_user(again.__metadata__.token).id == user.id
    end

    test "a session subject no longer resolves to a user" do
      user = register!()
      subject = AshAuthentication.user_to_subject(user)

      assert {:ok, %{id: id}} = AshAuthentication.subject_to_user(subject, User)
      assert id == user.id

      deactivate!(user)
      assert {:error, _} = AshAuthentication.subject_to_user(subject, User)
    end

    test "the revocation is stored, not only implied by the user filter" do
      user = register!()
      {:ok, signed_in} = sign_in(user)
      {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(signed_in.__metadata__.token)

      deactivate!(user)

      assert {:ok, true} =
               AshEnterprise.Accounts.Token
               |> Ash.ActionInput.for_action(:revoked?, %{jti: jti},
                 context: %{private: %{ash_authentication?: true}}
               )
               |> Ash.run_action()
    end
  end

  describe "other doors" do
    test "the lookup behind a password reset finds nobody deactivated, so no reset is sent" do
      user = register!()
      assert {:ok, %{id: id}} = Accounts.get_active_user_by_email(user.email, authorize?: false)
      assert id == user.id

      deactivate!(user)
      assert {:error, _} = Accounts.get_active_user_by_email(user.email, authorize?: false)
    end

    test "a password reset token for a deactivated user does not reset" do
      user = register!()

      {:ok, token} =
        AshAuthentication.Strategy.Password.reset_token_for(
          AshAuthentication.Info.strategy!(User, :password),
          user
        )

      deactivated = deactivate!(user)

      assert {:error, _} =
               AshAuthentication.Strategy.action(
                 AshAuthentication.Info.strategy!(User, :password),
                 :reset,
                 %{
                   "reset_token" => token,
                   "password" => "another-password-99",
                   "password_confirmation" => "another-password-99"
                 }
               )

      # The refused reset changed nothing: the old password is still the password.
      activate!(deactivated)
      assert {:error, _} = sign_in(user, "another-password-99")
      assert {:ok, _} = sign_in(user)
    end
  end

  describe "explicit token lifetime" do
    test "a token lives for the configured lifetime, not the library's 14 days" do
      user = register!()
      {:ok, signed_in} = sign_in(user)

      {:ok, %{"exp" => exp, "iat" => iat}} =
        AshAuthentication.Jwt.peek(signed_in.__metadata__.token)

      {n, unit} = AshEnterprise.Accounts.TokenPolicy.lifetime()
      seconds = n * Map.fetch!(%{days: 86_400, hours: 3_600, minutes: 60, seconds: 1}, unit)

      assert exp - iat == seconds
      assert seconds < 14 * 86_400
    end

    test "the lifetime on the resource is the policy's, so a host's setting reaches it" do
      assert {:ok, AshEnterprise.Accounts.TokenPolicy.lifetime()} ==
               AshAuthentication.Info.authentication_tokens_token_lifetime(User)
    end

    test "the policy refuses a malformed lifetime rather than defaulting" do
      for bad <- [nil, 0, {0, :hours}, {1, :weeks}, "8h", {-1, :days}] do
        assert_raise ArgumentError, fn -> AshEnterprise.Accounts.TokenPolicy.validate!(bad) end
      end

      assert {8, :hours} == AshEnterprise.Accounts.TokenPolicy.validate!({8, :hours})
    end
  end
end
