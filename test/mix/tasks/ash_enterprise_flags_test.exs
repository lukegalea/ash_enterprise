defmodule Mix.Tasks.AshEnterprise.FlagsTest do
  @moduledoc """
  `mix ash_enterprise.flags` flips a tenant's flags as the named person, through
  their grants (ADR 0072). SYNTHETIC data only; `test.alpha` is declared in
  config/test.exs.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  alias AshEnterprise.Flags
  alias Mix.Tasks.AshEnterprise.Flags, as: Task

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    %{admin: tenant!()}
  end

  defp run!(admin, email, args),
    do: Task.run(["--org", admin.organization.unique_name, "--as", email | args])

  defp flag(admin), do: Flags.get_flag!("test.alpha", actor: admin.actor, tenant: admin.tenant)

  test "a person without a grant on flags is refused", %{admin: admin} do
    member = member!(admin, "Member", [])

    assert_raise Mix.Error, ~r/could not change test.alpha/, fn ->
      run!(admin, member.email, ["on", "test.alpha"])
    end

    assert {:error, _} = Flags.get_flag("test.alpha", actor: admin.actor, tenant: admin.tenant)
  end

  test "an undeclared key is refused", %{admin: admin} do
    assert_raise Mix.Error, ~r/not a declared feature flag/, fn ->
      run!(admin, admin.email, ["on", "test.undeclared"])
    end
  end

  test "someone outside the tenant is refused", %{admin: admin} do
    other = tenant!()

    assert_raise Mix.Error, ~r/is not a member of/, fn ->
      run!(admin, other.email, ["list"])
    end
  end

  test "an administrator turns a flag on, targets it, lists it and turns it off", %{admin: admin} do
    run!(admin, admin.email, ["on", "test.alpha"])
    assert flag(admin).state == :on

    run!(admin, admin.email, [
      "target",
      "test.alpha",
      "--user",
      admin.user.id,
      "--percentage",
      "10"
    ])

    assert %{state: :targeted, user_ids: [id], percentage: 10} = flag(admin)
    assert id == admin.user.id

    run!(admin, admin.email, ["list"])
    assert_received {:mix_shell, :info, ["Feature flags in " <> _ = listing]}
    assert listing =~ "test.alpha: targeted (1 person, 10%)"
    assert listing =~ "test.beta: off (no row)"

    run!(admin, admin.email, ["off", "test.alpha"])
    assert flag(admin).state == :off
  end
end
