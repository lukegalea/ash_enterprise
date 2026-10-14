defmodule AshEnterpriseWeb.MdmSurfacesTest do
  @moduledoc """
  The MDM A2UI surfaces (MDM-6) are declared at their routes and derive
  valid A2UI messages from their resources — the canonical surfaces' test,
  pointed at the two MDM entries.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterpriseWeb.A2ui

  test "the MDM surfaces are declared at their routes" do
    surfaces = Enum.filter(A2ui.Surfaces.all(), &String.starts_with?(&1.name, "mdm_"))

    assert Enum.map(surfaces, & &1.name) == ["mdm_mappings", "mdm_golden"]

    assert Enum.map(surfaces, & &1.path) == [
             "/app/mdm/mappings",
             "/app/mdm/golden"
           ]
  end

  test "the MDM surfaces derive valid A2UI messages" do
    for ui <- [A2ui.MdmMappingUI, A2ui.MdmGoldenUI] do
      messages = AshA2ui.Info.build_surface(ui)

      assert messages != []
      assert Enum.all?(messages, &is_map/1)
    end
  end
end
