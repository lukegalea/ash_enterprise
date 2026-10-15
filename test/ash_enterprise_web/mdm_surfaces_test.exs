defmodule AshEnterpriseWeb.MdmSurfacesTest do
  @moduledoc """
  The MDM A2UI surfaces (MDM-6) are declared at their routes and derive
  valid A2UI messages from their resources — the canonical surfaces' test,
  pointed at the two MDM entries.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterpriseWeb.A2ui

  test "the MDM surfaces are declared at their routes, in the Master data group" do
    surfaces = Enum.filter(AshEnterprise.Surfaces.all(), &(&1.group == :mdm))

    assert Enum.map(surfaces, & &1.key) == [:steward, :mdm_import, :mdm_golden, :mdm_mappings]

    assert Enum.map(surfaces, & &1.path) == [
             "/app/mdm",
             "/app/mdm/import",
             "/app/mdm/golden",
             "/app/mdm/mappings"
           ]

    # The verdicts are person-gated by policy, not by a door: any signed-in
    # person may open the queue and sees what their grants let them read.
    assert Enum.all?(surfaces, &(&1.door == :signed_in))
  end

  test "the MDM surfaces derive valid A2UI messages" do
    for ui <- [A2ui.MdmMappingUI, A2ui.MdmGoldenUI] do
      messages = AshA2ui.Info.build_surface(ui)

      assert messages != []
      assert Enum.all?(messages, &is_map/1)
    end
  end
end
