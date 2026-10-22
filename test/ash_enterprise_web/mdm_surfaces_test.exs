defmodule AshEnterpriseWeb.MdmSurfacesTest do
  @moduledoc """
  The MDM A2UI surfaces (MDM-4/6) are declared at their routes and derive
  valid A2UI messages from their resources — the canonical surfaces' test,
  pointed at the MDM entries.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterpriseWeb.A2ui

  test "the MDM surfaces are declared at their routes, in the Master data group" do
    surfaces = Enum.filter(AshEnterprise.Surfaces.all(), &(&1.group == :mdm))

    assert Enum.map(surfaces, & &1.key) ==
             [:steward, :mdm_import, :mdm_golden, :time_travel, :mdm_mappings, :mdm_batches]

    assert Enum.map(surfaces, & &1.path) == [
             "/app/mdm",
             "/app/mdm/import",
             "/app/mdm/golden",
             "/app/time-travel",
             "/app/mdm/mappings",
             "/app/mdm/batches"
           ]

    # Every MDM surface but the import wizard and time travel is an A2UI surface with a
    # detail, so links and `/app/r/<surface>/<id>` open one record on it.
    assert for(%{ui: ui, context: context} = s <- surfaces, ui, do: {s.key, context}) == [
             steward: :candidate,
             mdm_golden: :person,
             mdm_mappings: :mapping,
             mdm_batches: :batch
           ]

    # The verdicts are person-gated by policy, not by a door: any signed-in
    # person may open the queue and sees what their grants let them read.
    assert Enum.all?(surfaces, &(&1.door == :signed_in))
  end

  test "the MDM surfaces derive valid A2UI messages" do
    for ui <- [A2ui.MdmStewardUI, A2ui.MdmMappingUI, A2ui.MdmGoldenUI, A2ui.MdmBatchUI] do
      messages = AshA2ui.Info.build_surface(ui)

      assert messages != []
      assert Enum.all?(messages, &is_map/1)
    end
  end
end
