defmodule AshEnterprise.Journeys.WorldTest do
  @moduledoc """
  The journeys' world, personas and surfaces without a browser: what
  `AshEnterprise.Journeys.World` seeds and pins, which user a persona is, and the
  surfaces a journey may name. The browser tier walks the journeys themselves
  (`test/e2e/journeys/journeys_test.exs`).

  Not async: the world seeds fixed people (`admin@example.com`), and two
  sandboxes inserting the same unique email wait on each other.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Journeys.Offboarding
  alias AshEnterprise.Journeys.Personas
  alias AshEnterprise.Journeys.Surfaces
  alias AshEnterprise.Journeys.World
  alias AshJourneys.Info

  @clock ~U[2026-03-02 09:00:00Z]

  defp world(overrides \\ []) do
    struct!(
      AshJourneys.Dsl.World,
      Keyword.merge(
        [
          packs: [],
          bind: [admin: {:tenant_admin, "admin"}, leaver: {:member, "dana"}],
          clock: @clock,
          timestamps: []
        ],
        overrides
      )
    )
  end

  test "the offboarding journey's world seeds its people and pins their timestamps" do
    journey = Info.journey!(Offboarding, :revoke_a_leavers_access)
    world = journey.world

    assert {:ok, %{admin: admin, leaver: leaver}} = World.seed(world, [])
    assert to_string(admin.email) == "admin@example.com"
    assert to_string(leaver.email) == "dana@example.com"
    assert leaver.lifecycle_status == :active
    assert admin.owning_business_unit_id == leaver.owning_business_unit_id

    pins = %{admin: %{created_on: 0}, leaver: %{created_on: 30 * 60}}
    assert :ok = World.pin_timestamps(%{admin: admin, leaver: leaver}, world.clock, pins)

    assert DateTime.compare(Ash.get!(User, admin.id, authorize?: false).created_on, @clock) ==
             :eq

    assert DateTime.compare(
             Ash.get!(User, leaver.id, authorize?: false).created_on,
             DateTime.add(@clock, 30, :minute)
           ) == :eq
  end

  test "a world binds exactly one administrator, and only the kinds it knows" do
    assert {:error, "a world binds exactly one" <> _} =
             World.seed(world(bind: [leaver: {:member, "dana"}]), [])

    assert {:error, "unknown bindings" <> _} =
             World.seed(world(bind: [admin: {:tenant_admin, "admin"}, x: {:robot, "r2"}]), [])

    assert {:error, "this world seeds no packs" <> _} =
             World.seed(world(packs: [:offboarding]), [])
  end

  test "a persona is the user bound under its name, seeded as its role" do
    {:ok, bindings} = World.seed(world(), [])

    assert {:ok, %User{} = admin} = Personas.actor(:tenant_admin, :admin, bindings)
    assert admin.id == bindings.admin.id
    assert {:ok, _leaver} = Personas.actor(:member, :leaver, bindings)

    assert {:error, "leaver was seeded as :member, not :tenant_admin"} =
             Personas.actor(:tenant_admin, :leaver, bindings)

    assert {:error, "the world bound no ghost"} = Personas.actor(:member, :ghost, bindings)
  end

  test "a journey can name registry surfaces with a path, the launcher and the sign-in page" do
    assert %{ui: AshEnterpriseWeb.A2ui.UserUI} = Surfaces.surface(:users)
    assert Surfaces.path(:users) == "/app/users"
    assert %{ui: nil} = Surfaces.surface(:launcher)
    assert Surfaces.path(:launcher) == "/app"
    assert %{ui: nil} = Surfaces.surface(:sign_in)
    assert Surfaces.path(:sign_in) == "/sign-in"
    assert Surfaces.surface(:no_such_surface) == nil
  end
end
