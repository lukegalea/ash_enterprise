defmodule AshEnterprise.Accounts.LockoutTest do
  @moduledoc """
  Repeated failed password sign-ins lock the identity out. The counter lives in
  Postgres (`AshEnterprise.Accounts.SignInLockout`) and is advanced by one atomic
  upsert, so two processes -- or two nodes -- cannot each see "4 of 5".

  A locked identity is refused even with the right password, and every refusal
  looks the same as a wrong password, so the lockout does not tell a caller
  whether an address is registered.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Accounts.{Lockout, SignInLockout, User}

  @password "test-password-1234"
  @t0 ~U[2026-11-09 12:00:00.000000Z]

  setup do
    previous = Application.get_env(:ash_enterprise, Lockout)

    Application.put_env(:ash_enterprise, Lockout,
      max_attempts: 5,
      window_seconds: 900,
      lockout_seconds: 900
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_enterprise, Lockout, previous),
        else: Application.delete_env(:ash_enterprise, Lockout)
    end)

    :ok
  end

  defp email, do: "lock-#{System.unique_integer([:positive])}@example.test"

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

  defp fail!(email, n), do: for(_ <- 1..n, do: {:error, _} = sign_in(email, "wrong-password"))

  describe "through the sign-in action" do
    test "five wrong passwords lock the identity, and the right password is then refused" do
      email = email()
      register!(email)

      fail!(email, 4)
      assert {:ok, _} = sign_in(email, @password), "below the limit the right password works"

      fail!(email, 5)
      assert {:error, _} = sign_in(email, @password)
    end

    test "a success below the limit resets the counter" do
      email = email()
      register!(email)

      fail!(email, 4)
      assert {:ok, _} = sign_in(email, @password)
      fail!(email, 4)
      assert {:ok, _} = sign_in(email, @password)
    end

    test "an unregistered address locks the same way, so lockout is not an oracle" do
      email = email()
      fail!(email, 5)
      assert {:locked, _} = Lockout.status(email)
    end

    test "a lockout on one identity leaves another alone" do
      a = email()
      b = email()
      register!(a)
      register!(b)

      fail!(a, 5)
      assert {:ok, _} = sign_in(b, @password)
    end

    test "case and surrounding space do not make a new identity" do
      email = email()
      register!(email)

      fail!(String.upcase(email), 3)
      fail!(" " <> email <> " ", 2)
      assert {:error, _} = sign_in(email, @password)
    end
  end

  describe "the counter" do
    test "counts failures from concurrent processes exactly" do
      key = email()

      Application.put_env(:ash_enterprise, Lockout,
        max_attempts: 1000,
        window_seconds: 900,
        lockout_seconds: 900
      )

      1..12
      |> Task.async_stream(fn _ -> Lockout.record_failure(key, now: @t0) end,
        max_concurrency: 12,
        timeout: 30_000
      )
      |> Enum.each(fn {:ok, result} -> assert {:ok, _} = result end)

      assert Lockout.failures(key) == 12
    end

    test "concurrent failures that cross the limit leave the identity locked" do
      key = email()

      1..8
      |> Task.async_stream(fn _ -> Lockout.record_failure(key, now: @t0) end,
        max_concurrency: 8,
        timeout: 30_000
      )
      |> Stream.run()

      assert {:locked, until} = Lockout.status(key, now: @t0)
      assert DateTime.diff(until, @t0) == 900
    end

    test "a lock holds until its moment and not a microsecond longer" do
      key = email()
      for _ <- 1..5, do: Lockout.record_failure(key, now: @t0)

      assert {:locked, until} = Lockout.status(key, now: @t0)
      assert {:locked, _} = Lockout.status(key, now: DateTime.add(until, -1, :microsecond))
      assert :open = Lockout.status(key, now: until)
    end

    test "failures outside the window start a new count" do
      key = email()
      for _ <- 1..4, do: Lockout.record_failure(key, now: @t0)

      later = DateTime.add(@t0, 901, :second)
      Lockout.record_failure(key, now: later)

      assert Lockout.failures(key) == 1
      assert :open = Lockout.status(key, now: later)
    end

    test "a failure while locked does not extend the lock" do
      key = email()
      for _ <- 1..5, do: Lockout.record_failure(key, now: @t0)
      {:locked, until} = Lockout.status(key, now: @t0)

      Lockout.record_failure(key, now: DateTime.add(@t0, 60, :second))
      assert {:locked, ^until} = Lockout.status(key, now: @t0)
    end

    test "clearing removes the count" do
      key = email()
      for _ <- 1..3, do: Lockout.record_failure(key, now: @t0)
      :ok = Lockout.clear(key)
      assert Lockout.failures(key) == 0
    end

    test "the stored key is a digest, never the address" do
      key = email()
      Lockout.record_failure(key, now: @t0)

      rows = Ash.read!(SignInLockout, authorize?: false)
      assert Enum.all?(rows, &(not String.contains?(&1.key, "@")))
    end
  end

  describe "inputs that are not an identity are never open" do
    test "a blank, nil or non-string key counts against a shared bucket instead of being skipped" do
      for bad <- [nil, "", "   ", 42, %{}] do
        assert {:ok, _} = Lockout.record_failure(bad, now: @t0)
      end

      assert Lockout.failures("") >= 1
    end

    test "a sign-in with no email at all fails and is counted" do
      strategy = AshAuthentication.Info.strategy!(User, :password)

      assert {:error, _} =
               AshAuthentication.Strategy.action(strategy, :sign_in, %{"password" => "x"})
    end

    test "an unreadable lockout store refuses the sign-in" do
      assert {:locked, :unknown} = Lockout.status_or_locked(fn -> {:error, :boom} end)
    end
  end

  describe "configuration" do
    test "limits are read at call time, so a host can set them" do
      key = email()

      Application.put_env(:ash_enterprise, Lockout,
        max_attempts: 2,
        window_seconds: 60,
        lockout_seconds: 30
      )

      for _ <- 1..2, do: Lockout.record_failure(key, now: @t0)
      assert {:locked, until} = Lockout.status(key, now: @t0)
      assert DateTime.diff(until, @t0) == 30
    end

    test "a malformed setting raises rather than disabling the lockout" do
      Application.put_env(:ash_enterprise, Lockout,
        max_attempts: 0,
        window_seconds: 60,
        lockout_seconds: 30
      )

      assert_raise ArgumentError, fn -> Lockout.limits() end

      Application.put_env(:ash_enterprise, Lockout,
        max_attempts: "five",
        window_seconds: 60,
        lockout_seconds: 30
      )

      assert_raise ArgumentError, fn -> Lockout.limits() end
    end
  end
end
