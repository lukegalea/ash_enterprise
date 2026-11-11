defmodule AshEnterprise.Accounts.ApiKeyTest do
  @moduledoc """
  A bearer key has an expiry and is only as alive as its owner: it stops working
  when it expires, when it is revoked and when its owner is deactivated, and
  reactivating the owner does not revive a key that expired meanwhile.

  Keys are authenticated through `AshEnterpriseWeb.Plugs.LoadFromBearer`, the
  plug the API pipelines use, so these are the doors the API actually has.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Accounts.{ApiKey, User}
  alias AshEnterpriseWeb.Plugs.LoadFromBearer

  @password "test-password-1234"

  defp register! do
    User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{
        email: "key-#{System.unique_integer([:positive])}@example.test",
        password: @password,
        password_confirmation: @password
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp issue(user, attrs \\ %{}) do
    ApiKey
    |> Ash.Changeset.for_create(
      :issue,
      Map.merge(
        %{user_id: user.id, name: "ci", expires_at: DateTime.add(DateTime.utc_now(), 3600)},
        attrs
      ),
      authorize?: false
    )
    |> Ash.create()
  end

  defp issue!(user, attrs \\ %{}) do
    {:ok, key} = issue(user, attrs)
    key
  end

  defp plaintext(key), do: key.__metadata__.plaintext_api_key

  defp call(bearer) do
    Plug.Test.conn(:get, "/")
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> bearer)
    |> LoadFromBearer.call(LoadFromBearer.init([]))
  end

  defp authenticated_as(conn), do: conn.assigns[:current_user] && conn.assigns.current_user.id

  defp expire!(key, at) do
    Ecto.Adapters.SQL.query!(Repo, "UPDATE api_keys SET expires_at = $1 WHERE id = $2", [
      at,
      Ecto.UUID.dump!(key.id)
    ])
  end

  defp deactivate!(user) do
    user |> Ash.Changeset.for_update(:deactivate, %{}, authorize?: false) |> Ash.update!()
  end

  test "a live key authenticates its owner" do
    user = register!()
    key = issue!(user)

    conn = call(plaintext(key))
    refute conn.halted
    assert authenticated_as(conn) == user.id
  end

  test "an expired key is refused" do
    user = register!()
    key = issue!(user)
    expire!(key, DateTime.add(DateTime.utc_now(), -1))

    conn = call(plaintext(key))
    assert conn.halted
    assert conn.status == 401
    assert authenticated_as(conn) == nil
  end

  test "a key is refused at the moment it expires" do
    user = register!()
    key = issue!(user)
    expire!(key, DateTime.utc_now())

    assert call(plaintext(key)).status == 401
  end

  test "a live key whose owner is deactivated is refused" do
    user = register!()
    key = issue!(user)
    assert authenticated_as(call(plaintext(key))) == user.id

    deactivate!(user)

    conn = call(plaintext(key))
    assert conn.halted
    assert conn.status == 401
  end

  test "reactivating the owner revives a live key but not an expired one" do
    user = register!()
    live = issue!(user)
    stale = issue!(user)

    user = deactivate!(user)
    expire!(stale, DateTime.add(DateTime.utc_now(), -60))
    user |> Ash.Changeset.for_update(:activate, %{}, authorize?: false) |> Ash.update!()

    assert authenticated_as(call(plaintext(live))) == user.id
    assert call(plaintext(stale)).status == 401
  end

  test "a revoked key is refused" do
    user = register!()
    key = issue!(user)
    Ash.destroy!(key, authorize?: false)

    assert call(plaintext(key)).status == 401
  end

  test "a key cannot be issued without an expiry, in the past, or beyond the maximum" do
    user = register!()

    assert {:error, _} = issue(user, %{expires_at: nil})
    assert {:error, _} = issue(user, %{expires_at: DateTime.add(DateTime.utc_now(), -60)})

    max_days = ApiKey.max_lifetime_days()
    too_far = DateTime.add(DateTime.utc_now(), (max_days + 1) * 86_400)
    assert {:error, _} = issue(user, %{expires_at: too_far})

    ok = DateTime.add(DateTime.utc_now(), (max_days - 1) * 86_400)
    assert {:ok, _} = issue(user, %{expires_at: ok})
  end

  test "a key cannot be issued for a deactivated owner" do
    user = register!() |> deactivate!()
    assert {:error, _} = issue(user)
  end

  test "only the hash is stored" do
    user = register!()
    key = issue!(user)

    stored = Ash.get!(ApiKey, key.id, authorize?: false)
    refute String.contains?(inspect(stored.api_key_hash), plaintext(key))
    assert byte_size(stored.api_key_hash) == 32
  end

  describe "malformed and missing keys are never a pass" do
    test "a key with the right prefix and nothing after it" do
      assert call("aek_").status == 401
    end

    test "a key with a bad checksum" do
      user = register!()
      key = plaintext(issue!(user))

      tampered =
        String.slice(key, 0..-2//1) <> if(String.ends_with?(key, "a"), do: "b", else: "a")

      assert authenticated_as(call(tampered)) == nil
    end

    test "random text under the key prefix" do
      assert call("aek_" <> Base.encode64(:crypto.strong_rand_bytes(48))).status == 401
    end

    test "no header at all authenticates nobody and halts nothing, leaving the policies to refuse" do
      conn =
        Plug.Test.conn(:get, "/")
        |> LoadFromBearer.call(LoadFromBearer.init([]))

      refute conn.halted
      assert authenticated_as(conn) == nil
    end

    test "a bearer value that is neither a key nor a token authenticates nobody" do
      conn = call("not-a-token")
      assert authenticated_as(conn) == nil
    end
  end

  test "a session token still authenticates through the same plug" do
    user = register!()
    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, signed_in} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => to_string(user.email),
        "password" => @password
      })

    assert authenticated_as(call(signed_in.__metadata__.token)) == user.id
  end
end
