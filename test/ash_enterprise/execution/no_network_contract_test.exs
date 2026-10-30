defmodule AshEnterprise.Execution.NoNetworkContractTest do
  @moduledoc """
  The no-network contract (ADR 0055, plan risk 5), a CI gate: every target declared
  internal (`open_world?: false`) that can change something attaches no transaction
  hook and makes no outbound request when it runs, inside a transaction that is rolled
  back, with every outbound request blocked. See
  `AshEnterprise.Test.Execution.NoNetwork`.

  A target that fails this must either lose the hook or be declared open-world, which
  moves it to the path whose guarantee does not depend on it.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]

  alias AshEnterprise.Test.Execution.{ClinicNote, LeakyNote, NoNetwork}

  setup do
    NoNetwork.block!()
    admin = tenant!()
    %{opts: [actor: admin.actor, tenant: admin.tenant]}
  end

  test "every internal target attaches no transaction hook and makes no outbound call",
       %{opts: opts} do
    targets =
      NoNetwork.inventory() ++
        for action <- [
              :record,
              :record_reviewed,
              :record_screened,
              :retitle,
              :retitle_reviewed,
              :record_approved
            ],
            do: {ClinicNote, action}

    # The inventory is not empty: the platform declares internal targets of its own.
    assert {AshEnterprise.Security.UserRole, :assign} in targets

    violations =
      Enum.flat_map(targets, fn {resource, action} -> NoNetwork.check(resource, action, opts) end)

    assert violations == []
  end

  test "a target whose hook calls out fails the contract", %{opts: opts} do
    assert [hook, call] = NoNetwork.check(LeakyNote, :record_and_tell, opts)
    assert hook =~ "after_transaction hook"
    assert call =~ "called out: POST"
  end
end
