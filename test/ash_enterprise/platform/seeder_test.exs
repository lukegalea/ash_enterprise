defmodule AshEnterprise.Platform.SeederTest do
  @moduledoc """
  That the seed path works without the Phoenix endpoint, as it runs inside
  `mix ash_enterprise.seed` and `mix ash_enterprise.demo`.

  Both tasks boot only the Repo (iron law #23). On a fresh database the tenant
  half of `mix ash_enterprise.seed` crashed with "could not find persistent
  term for endpoint AshEnterpriseWeb.Endpoint": the administrator was created
  through `:register_with_password`, whose confirmation sender builds its link
  with `url/1` against the endpoint. Seen on 2026-10-12 and 2026-10-14.

  The test environment starts the endpoint, so these tests remove the
  endpoint's persistent term for their duration. That is exactly the state a
  Repo-only mix task is in, and `url/1` raises the same error in it. The
  module is `async: false` so no concurrent test is generating URLs meanwhile.
  """

  use AshEnterprise.DataCase, async: false

  import Swoosh.TestAssertions

  require Ash.Query

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Platform.{DemoData, Seeder}

  @endpoint_term {Phoenix.Endpoint, AshEnterpriseWeb.Endpoint}

  defp unique, do: System.unique_integer([:positive])

  defp sign_in(email, password) do
    User
    |> AshAuthentication.Info.strategy!(:password)
    |> AshAuthentication.Strategy.action(:sign_in, %{"email" => email, "password" => password})
  end

  describe "without the endpoint running" do
    setup do
      saved = :persistent_term.get(@endpoint_term)
      :persistent_term.erase(@endpoint_term)
      on_exit(fn -> :persistent_term.put(@endpoint_term, saved) end)
      :ok
    end

    test "the condition is real: url/1 cannot be built" do
      assert_raise RuntimeError, ~r/could not find persistent term for endpoint/, fn ->
        AshEnterpriseWeb.Endpoint.url()
      end
    end

    test "seed_tenant/1 provisions a confirmed administrator who can sign in, and sends nothing" do
      n = unique()
      email = "seed-#{n}@example.com"

      seeded =
        Seeder.seed_tenant(
          name: "Seed #{n}",
          unique_name: "seed-#{n}",
          email: email,
          password: "seed-password-1234"
        )

      assert seeded.user.email |> to_string() == email
      assert %DateTime{} = seeded.user.confirmed_at
      assert_no_email_sent()

      assert {:ok, signed_in} = sign_in(email, "seed-password-1234")
      assert signed_in.id == seeded.user.id
    end

    test "mix ash_enterprise.seed provisions the tenant" do
      n = unique()
      email = "task-#{n}@example.com"
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      Mix.Task.rerun("ash_enterprise.seed", [
        "--email",
        email,
        "--name",
        "Task #{n}",
        "--unique-name",
        "task-#{n}"
      ])

      assert_received {:mix_shell, :info, ["\nProvisioned tenant " <> provisioned]}
      assert provisioned =~ "Task #{n}"
      user = Ash.read_one!(Ash.Query.filter(User, email == ^email), authorize?: false)
      assert %DateTime{} = user.confirmed_at
      assert_no_email_sent()
    end

    test "DemoData.populate/1 provisions its people the same way" do
      n = unique()

      seeded =
        Seeder.seed_tenant(
          name: "Demo #{n}",
          unique_name: "demo-#{n}",
          email: "demo-#{n}@example.com"
        )

      counts = DemoData.populate(seeded.organization.id)

      assert counts.users > 0
      assert_no_email_sent()
    end
  end

  describe ":provision_with_password" do
    test "refuses anyone but a system actor, including trusted code with authorization off" do
      changeset =
        Ash.Changeset.for_create(
          User,
          :provision_with_password,
          %{email: "nobody-#{unique()}@example.com", password: "password1234"},
          authorize?: false
        )

      assert {:error, %Ash.Error.Invalid{} = error} = Ash.create(changeset)
      assert Exception.message(error) =~ "only a system actor"
    end

    test "refuses a signed-in person, even an Administrator" do
      n = unique()

      seeded =
        Seeder.seed_tenant(
          name: "Admin #{n}",
          unique_name: "admin-#{n}",
          email: "admin-#{n}@example.com"
        )

      result =
        User
        |> Ash.Changeset.for_create(
          :provision_with_password,
          %{email: "bypass-#{n}@example.com", password: "password1234"},
          actor: seeded.user
        )
        |> Ash.create()

      assert {:error, %Ash.Error.Invalid{} = error} = result
      assert Exception.message(error) =~ "only a system actor"

      refute Ash.read_one!(Ash.Query.filter(User, email == ^"bypass-#{n}@example.com"),
               authorize?: false
             )
    end
  end

  test "registration still requires confirmation" do
    email = "register-#{unique()}@example.com"

    user =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: "password1234", password_confirmation: "password1234"},
        authorize?: false
      )
      |> Ash.create!()

    assert is_nil(user.confirmed_at)
    assert_email_sent(subject: "Confirm your email address", to: [{"", email}])
  end
end
