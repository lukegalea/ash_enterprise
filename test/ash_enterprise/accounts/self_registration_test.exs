defmodule AshEnterprise.Accounts.SelfRegistrationTest do
  @moduledoc """
  `/register` creates an account only where self-registration is on (dev and the
  suite). A release leaves it off, and then `:register_with_password` fails before
  anything is written, whatever `authorize?` says. Provisioning by the operator is
  unaffected.

  The flag is application environment, which is global: not async.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Platform.Seeder

  @password "self-registration-1234"

  setup do
    previous = Application.get_env(:ash_enterprise, :self_registration?)
    on_exit(fn -> Application.put_env(:ash_enterprise, :self_registration?, previous) end)
    :ok
  end

  defp email, do: "self-registration-#{System.unique_integer([:positive])}@example.test"

  defp register(email) do
    User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{email: email, password: @password, password_confirmation: @password},
      authorize?: false
    )
    |> Ash.create()
  end

  defp exists?(email) do
    User
    |> Ash.Query.filter(email == ^email)
    |> Ash.exists?(authorize?: false)
  end

  test "the configuration a release boots with leaves it off" do
    {config, _files} = Config.Reader.read_imports!("config/config.exs", env: :prod)
    assert get_in(config, [:ash_enterprise, :self_registration?]) == false
  end

  test "on, registration creates the account" do
    Application.put_env(:ash_enterprise, :self_registration?, true)
    email = email()

    assert {:ok, user} = register(email)
    assert to_string(user.email) == email
  end

  test "off, registration is refused on the email and writes nothing" do
    Application.put_env(:ash_enterprise, :self_registration?, false)
    email = email()

    assert {:error, %Ash.Error.Invalid{errors: errors}} = register(email)
    assert Enum.any?(errors, &refused_registration?/1)
    refute exists?(email)
  end

  test "off, the operator still provisions accounts" do
    Application.put_env(:ash_enterprise, :self_registration?, false)
    email = email()

    user = Seeder.provision_user!(email, @password)
    assert to_string(user.email) == email
  end

  defp refused_registration?(error),
    do:
      Map.get(error, :field) == :email and
        Map.get(error, :message, "") =~ "Registration is disabled"
end
