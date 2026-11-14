defmodule AshEnterprise.Accounts.OidcSignInTest do
  @moduledoc """
  Sign-in through the deployment's OpenID Connect identity provider (ADR 0071).

  A first federated sign-in reaches only an existing user who is active, has confirmed
  their address here, and whose email the provider asserts as verified. Nothing is
  provisioned, a provider subject belongs to one user, and a user has one subject.
  Every attempt is recorded at the `:oidc` door without the email.

  Driven through the strategy's sign-in action with what a provider would assert after
  its callback, so no provider is called: the callback's HTTP leg is `assent`'s.

  Fault points are application environment: not async.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Accounts.{TokenPolicy, User, UserIdentity}
  alias AshEnterprise.Faults
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Repo
  alias AshEnterprise.Security.AuthenticationEvent

  @password "oidc-sign-in-1234"

  setup do
    on_exit(&Faults.disarm_all/0)
    :ok
  end

  describe "refused" do
    test "an unknown email is refused and no user is created" do
      users_before = count(User)
      identities_before = count(UserIdentity)

      assert {:error, _} = sign_in(user_info(email()))

      assert count(User) == users_before
      assert count(UserIdentity) == identities_before

      assert [%{door: :oidc, outcome: :refused, reason: :unknown_identity, user_id: nil}] =
               new_events_since_setup()
    end

    test "a provider that asserts no email is refused" do
      assert {:error, _} = sign_in(Map.delete(user_info(email()), "email"))
      assert [%{reason: :unknown_identity, user_id: nil}] = new_events_since_setup()
    end

    test "an email the provider does not mark verified is refused" do
      user = provision!()

      assert {:error, _} = sign_in(user_info(user.email, email_verified: false))
      assert {:error, _} = sign_in(Map.delete(user_info(user.email), "email_verified"))

      assert linked(user) == []
      assert [%{reason: :unverified_email}, %{reason: :unverified_email}] = events(user.id)
    end

    test "a matching but unconfirmed local user is refused" do
      user = register_unconfirmed!()
      assert is_nil(user.confirmed_at)

      assert {:error, _} = sign_in(user_info(user.email))

      assert linked(user) == []
      assert [%{reason: :unconfirmed}] = events(user.id)
    end

    test "a deactivated user is refused" do
      user = provision!()
      deactivate!(user)

      assert {:error, _} = sign_in(user_info(user.email))

      assert linked(user) == []
      assert [%{reason: :inactive}] = events(user.id)
    end

    test "a deactivated user already linked is refused" do
      user = provision!()
      info = user_info(user.email)
      assert {:ok, _} = sign_in(info)
      deactivate!(user)

      assert {:error, _} = sign_in(info)
      assert [%{outcome: :signed_in}, %{reason: :inactive}] = events(user.id)
    end

    test "a provider identity linked to another user is refused" do
      first = provision!()
      second = provision!()
      sub = "subject-#{System.unique_integer([:positive])}"
      assert {:ok, _} = sign_in(user_info(first.email, sub: sub))

      # The same provider subject now asserts the second user's address.
      assert {:error, _} = sign_in(user_info(second.email, sub: sub))

      assert linked(second) == []
      assert [%{user_id: first_id}] = linked(first)
      assert first_id == first.id
      assert [%{reason: :identity_mismatch}] = events(second.id)
    end

    test "a second provider identity for an already-linked account is refused" do
      user = provision!()
      assert {:ok, _} = sign_in(user_info(user.email))

      assert {:error, _} = sign_in(user_info(user.email))

      assert [_one] = linked(user)
      assert [%{outcome: :signed_in}, %{reason: :identity_mismatch}] = events(user.id)
    end

    test "a refusal is recorded at the oidc door without the email" do
      unknown = email()
      user = provision!()

      assert {:error, _} = sign_in(user_info(unknown))
      assert {:error, _} = sign_in(user_info(user.email, email_verified: false))

      assert [%{door: :oidc, user_id: nil}, %{door: :oidc, user_id: user_id}] =
               new_events_since_setup()

      assert user_id == user.id

      for event <- new_events_since_setup() do
        refute inspect(event) =~ unknown
        refute inspect(event) =~ to_string(user.email)
      end

      refute_spelled_anywhere(unknown)
    end
  end

  describe "admitted" do
    test "a verified, confirmed, active user signs in, the identity is recorded, and the token lives the configured 8 hours" do
      user = provision!()
      sub = "subject-#{System.unique_integer([:positive])}"

      # The provider's casing need not match the address as it was provisioned.
      assert {:ok, signed_in} = sign_in(user_info(String.upcase(to_string(user.email)), sub: sub))
      assert signed_in.id == user.id

      assert [identity] = linked(user)
      assert identity.uid == sub and identity.strategy == "oidc"
      # The provider's tokens are not kept.
      assert identity.access_token == nil and identity.refresh_token == nil

      token = signed_in.__metadata__.token
      assert is_binary(token)
      {:ok, claims} = AshAuthentication.Jwt.peek(token)
      assert claims["exp"] - claims["iat"] == TokenPolicy.seconds()
      assert TokenPolicy.seconds() == 8 * 3600

      # A later sign-in by the same subject is the same link.
      assert {:ok, again} = sign_in(user_info(user.email, sub: sub))
      assert again.id == user.id
      assert [_one] = linked(user)
    end

    test "the admission is recorded at the oidc door, and an unrecordable admission grants nothing" do
      user = provision!()
      assert {:ok, _} = sign_in(user_info(user.email))
      assert [%{door: :oidc, outcome: :signed_in, reason: nil}] = events(user.id)

      other = provision!()
      Faults.arm(:authentication_event_record, :raise)

      assert {:error, _} = sign_in(user_info(other.email))
      assert events(other.id) == []
    end

    test "no user is ever created through the provider" do
      refute AshAuthentication.Info.strategy!(User, :oidc).registration_enabled?
      refute Ash.Resource.Info.action(User, :register_with_oidc)
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp email, do: "oidc-#{System.unique_integer([:positive])}@example.test"

  defp user_info(email, opts \\ []) do
    %{
      "sub" => Keyword.get(opts, :sub, "subject-#{System.unique_integer([:positive])}"),
      "email" => to_string(email),
      "email_verified" => Keyword.get(opts, :email_verified, true),
      "name" => "Federated Person"
    }
  end

  defp sign_in(user_info) do
    strategy = AshAuthentication.Info.strategy!(User, :oidc)

    AshAuthentication.Strategy.action(strategy, :sign_in, %{
      "user_info" => user_info,
      "oauth_tokens" => %{
        "access_token" => "provider-access-token",
        "refresh_token" => "provider-refresh-token",
        "expires_in" => 3600
      }
    })
  end

  defp provision!, do: Seeder.provision_user!(email(), @password)

  defp register_unconfirmed! do
    User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{email: email(), password: @password, password_confirmation: @password},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp deactivate!(user) do
    user |> Ash.Changeset.for_update(:deactivate, %{}, authorize?: false) |> Ash.update!()
  end

  defp count(resource), do: Ash.count!(resource, authorize?: false)

  defp linked(user) do
    UserIdentity
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.read!(authorize?: false)
  end

  defp all_events do
    AuthenticationEvent
    |> Ash.Query.filter(door == :oidc)
    |> Ash.Query.sort(occurred_at: :asc)
    |> Ash.read!(actor: SystemActor.sign_in())
  end

  defp events(user_id), do: Enum.filter(all_events(), &(&1.user_id == user_id))

  # The sandbox starts every test empty of oidc events, so all of them are this test's.
  defp new_events_since_setup, do: all_events()

  defp refute_spelled_anywhere(fragment) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM audit_events
        WHERE strpos(data::text || changed_attributes::text || metadata::text, $1) > 0
        """,
        [fragment]
      )

    assert count == 0, "#{count} audit event(s) spell #{inspect(fragment)}"
  end
end
