defmodule AshEnterpriseWeb.LegacySurfacesTest do
  use AshEnterprise.DataCase, async: false

  alias AshEnterpriseWeb.A2ui.Surfaces

  @legacy_names ~w(
    legacy_users
    legacy_parties
    legacy_vendor_parties
    legacy_enterprise_parties
    legacy_contracting_processes
    legacy_party_roles
    legacy_contracts
    legacy_contract_lines
    legacy_commitments
  )

  test "catalogue exposes every compatibility surface at a legacy route" do
    surfaces = Enum.filter(Surfaces.all(), &String.starts_with?(&1.name, "legacy_"))

    assert Enum.map(surfaces, & &1.name) == @legacy_names
    assert Enum.all?(surfaces, &String.starts_with?(&1.path, "/app/legacy-"))
    assert Enum.all?(surfaces, fn surface -> Surfaces.fetch(surface.name) == surface end)
  end

  test "compatibility surfaces derive valid A2UI messages" do
    for surface <- Surfaces.all(), String.starts_with?(surface.name, "legacy_") do
      messages = AshA2ui.Info.build_surface(surface.ui)

      assert messages != []
      assert Enum.all?(messages, &is_map/1)
    end
  end

  test "legacy helper declares only read tools in legacy vocabulary" do
    tools = AshAi.Info.tools(AshEnterprise.LegacyAgent)

    assert Enum.sort(Enum.map(tools, &to_string(&1.name))) == Enum.sort(@legacy_names)
    assert Enum.all?(tools, &(&1.action == :read))
    assert Enum.all?(tools, &String.starts_with?(to_string(&1.name), "legacy_"))
  end
end
