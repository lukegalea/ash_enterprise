defmodule AshEnterprise.Security.AuthenticationEventTest do
  @moduledoc """
  The sign-in doors write to the audit chain (SOC 2 CC7.2). Every password sign-in and
  every refusal reason is a `Security.AuthenticationEvent` carrying the user it resolved
  to and never an email, and the audit log holds the write, in the untenanted chain. A
  reset and a confirmation record their admissions. The API key door records its
  refusals and nothing for a request it admits. A sign-in the chain cannot hold is not
  granted.

  Fault points and the lockout's limits are application environment: not async.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Accounts.{ApiKey, Lockout, User}
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Faults
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Repo
  alias AshEnterprise.Security
  alias AshEnterprise.Security.{ActorContext, AuthenticationEvent}
  alias AshEnterpriseWeb.Plugs.LoadFromBearer

  @password "authentication-event-1234"

  setup do
    previous = Application.get_env(:ash_enterprise, Lockout)

    Application.put_env(:ash_enterprise, Lockout,
      max_attempts: 3,
      window_seconds: 900,
      lockout_seconds: 900
    )

    on_exit(fn ->
      Faults.disarm_all()

      if previous,
        do: Application.put_env(:ash_enterprise, Lockout, previous),
        else: Application.delete_env(:ash_enterprise, Lockout)
    end)

    :ok
  end

  describe "the password door" do
    test "a sign-in is an event with the user, and the untenanted chain holds it" do
      user = register!()
      assert {:ok, signed_in} = sign_in(user.email, @password)
      assert signed_in.id == user.id

      assert [event] = events(user.id)
      assert event.door == :password and event.outcome == :signed_in and event.reason == nil

      assert [%{action: :record, action_type: :create} = entry] = logged(event)
      assert entry.organization_id == nil
      assert entry.data["user_id"] == user.id
      refute inspect(entry) =~ to_string(user.email)
      refute inspect(event) =~ to_string(user.email)
      assert %{findings: []} = AshEvents.Chain.verify(EventLog, nil)
    end

    test "a wrong password is a refusal with the user" do
      user = register!()
      assert {:error, _} = sign_in(user.email, "not-the-password")

      assert [%{door: :password, outcome: :refused, reason: :wrong_password}] = events(user.id)
    end

    test "an address that is no account is a refusal with no user, and the address is nowhere" do
      email = email()

      assert [event] = new_events(fn -> assert {:error, _} = sign_in(email, @password) end)
      assert event.door == :password and event.outcome == :refused
      assert event.reason == :unknown_identity
      assert event.user_id == nil

      refute_spelled_anywhere(email)
    end

    test "a deactivated user is refused as inactive, even with the right password" do
      user = register!()
      deactivate!(user)

      assert {:error, _} = sign_in(user.email, @password)
      assert [%{outcome: :refused, reason: :inactive}] = events(user.id)
    end

    test "a locked identity is refused as locked, even with the right password" do
      user = register!()
      for _ <- 1..3, do: assert({:error, _} = sign_in(user.email, "not-the-password"))

      assert {:error, _} = sign_in(user.email, @password)

      reasons = user.id |> events() |> Enum.map(& &1.reason)
      assert Enum.count(reasons, &(&1 == :wrong_password)) == 3
      assert List.last(reasons) == :locked
    end

    test "a sign-in the chain cannot hold is not granted" do
      user = register!()
      Faults.arm(:authentication_event_record, :raise)

      assert {:error, _} = sign_in(user.email, @password)
      assert events(user.id) == []
    end

    test "a refusal the chain cannot hold is still refused" do
      user = register!()
      Faults.arm(:authentication_event_record, :raise)

      assert {:error, _} = sign_in(user.email, "not-the-password")
      assert events(user.id) == []
    end
  end

  describe "the reset and confirmation doors" do
    test "a password reset that signs the user in is an admission" do
      user = register!()
      strategy = AshAuthentication.Info.strategy!(User, :password)
      {:ok, token} = AshAuthentication.Strategy.Password.reset_token_for(strategy, user)

      assert {:ok, reset} =
               AshAuthentication.Strategy.action(strategy, :reset, %{
                 "reset_token" => token,
                 "password" => "another-password-99",
                 "password_confirmation" => "another-password-99"
               })

      assert is_binary(reset.__metadata__.token)
      assert [%{door: :password_reset, outcome: :signed_in}] = events(user.id)
    end

    test "a reset the chain cannot hold changes nothing" do
      user = register!()
      strategy = AshAuthentication.Info.strategy!(User, :password)
      {:ok, token} = AshAuthentication.Strategy.Password.reset_token_for(strategy, user)
      Faults.arm(:authentication_event_record, :raise)

      assert {:error, _} =
               AshAuthentication.Strategy.action(strategy, :reset, %{
                 "reset_token" => token,
                 "password" => "another-password-99",
                 "password_confirmation" => "another-password-99"
               })

      assert events(user.id) == []
      assert {:ok, _} = sign_in(user.email, @password)
    end

    test "a confirmation that signs the user in is an admission" do
      user = register!()
      strategy = AshAuthentication.Info.strategy!(User, :confirm_new_user)

      {:ok, token} =
        AshAuthentication.AddOn.Confirmation.confirmation_token(
          strategy,
          Ash.Changeset.new(user),
          user
        )

      assert {:ok, _confirmed} =
               AshAuthentication.Strategy.action(strategy, :confirm, %{"confirm" => token})

      assert [%{door: :confirmation, outcome: :signed_in}] = events(user.id)
    end
  end

  describe "the API key door" do
    test "records each refusal and nothing for an admitted request" do
      user = register!()
      key = issue!(user)

      assert [] = new_events(fn -> assert call(plaintext(key)).assigns.current_user end)

      for bearer <- ["aek_", "aek_" <> Base.encode64(:crypto.strong_rand_bytes(48))] do
        assert [event] = new_events(fn -> assert call(bearer).status == 401 end)
        assert event.door == :api_key and event.outcome == :refused
        assert event.reason == :api_key_rejected
        assert event.user_id == nil
      end

      deactivate!(user)

      assert [%{door: :api_key, reason: :api_key_rejected}] =
               new_events(fn -> assert call(plaintext(key)).status == 401 end)
    end
  end

  test "no event can be written by a person, only by the door" do
    user = register!()

    actor =
      ActorContext.attach(user, %ActorContext{user_id: user.id, principal_ids: [user.id]})

    assert {:error, %Ash.Error.Forbidden{}} =
             Security.record_authentication_event(
               %{door: :password, outcome: :signed_in, user_id: user.id},
               actor: actor
             )
  end

  test "a person who is not the platform operator reads none of them" do
    user = register!()
    assert {:ok, _} = sign_in(user.email, @password)

    actor =
      ActorContext.attach(user, %ActorContext{user_id: user.id, principal_ids: [user.id]})

    case Ash.read(AuthenticationEvent, actor: actor) do
      {:ok, rows} -> assert rows == []
      {:error, error} -> assert %Ash.Error.Forbidden{} = error
    end
  end

  test "an event with the wrong shape is refused" do
    record = &Security.record_authentication_event(&1, actor: SystemActor.sign_in())
    id = Ash.UUID.generate()

    assert {:ok, _} = record.(%{door: :password, outcome: :signed_in, user_id: id})
    assert {:error, _} = record.(%{door: :password, outcome: :refused, user_id: id})

    assert {:error, _} =
             record.(%{door: :password, outcome: :signed_in, reason: :locked, user_id: id})

    assert {:error, _} = record.(%{door: :password, outcome: :signed_in})
    assert {:error, _} = record.(%{door: :password, outcome: :refused, reason: :made_up})
    assert {:error, _} = record.(%{door: :phone, outcome: :refused, reason: :locked})
  end

  defp email, do: "auth-event-#{System.unique_integer([:positive])}@example.test"

  defp register! do
    User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{email: email(), password: @password, password_confirmation: @password},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp sign_in(email, password) do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    AshAuthentication.Strategy.action(strategy, :sign_in, %{
      "email" => to_string(email),
      "password" => password
    })
  end

  defp deactivate!(user) do
    user |> Ash.Changeset.for_update(:deactivate, %{}, authorize?: false) |> Ash.update!()
  end

  defp issue!(user) do
    ApiKey
    |> Ash.Changeset.for_create(
      :issue,
      %{user_id: user.id, name: "ci", expires_at: DateTime.add(DateTime.utc_now(), 3600)},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp plaintext(key), do: key.__metadata__.plaintext_api_key

  defp call(bearer) do
    Plug.Test.conn(:get, "/")
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> bearer)
    |> LoadFromBearer.call(LoadFromBearer.init([]))
  end

  defp all_events do
    AuthenticationEvent
    |> Ash.Query.sort(occurred_at: :asc)
    |> Ash.read!(actor: SystemActor.sign_in())
  end

  defp events(user_id), do: Enum.filter(all_events(), &(&1.user_id == user_id))

  # The events `fun` wrote, in order.
  defp new_events(fun) do
    before = MapSet.new(all_events(), & &1.id)
    fun.()
    Enum.reject(all_events(), &MapSet.member?(before, &1.id))
  end

  defp logged(event) do
    EventLog
    |> Ash.Query.filter(record_id == ^event.id)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.resource == AuthenticationEvent))
  end

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
