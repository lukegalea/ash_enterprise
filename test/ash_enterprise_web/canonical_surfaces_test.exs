defmodule AshEnterpriseWeb.CanonicalSurfacesTest do
  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.CanonicalAgent
  alias AshEnterpriseWeb.A2ui
  alias AshEnterpriseWeb.A2ui.Surfaces

  @canonical_names ~w(canonical_parties canonical_contracts canonical_commitments)

  test "catalogue exposes canonical surfaces at canonical routes" do
    surfaces = Enum.filter(Surfaces.all(), &String.starts_with?(&1.name, "canonical_"))

    assert Enum.map(surfaces, & &1.name) == @canonical_names

    assert Enum.map(surfaces, & &1.path) == [
             "/app/canonical-parties",
             "/app/canonical-contracts",
             "/app/canonical-commitments"
           ]

    assert Enum.all?(surfaces, &(Surfaces.fetch(&1.name) == &1))
  end

  test "canonical surfaces derive valid A2UI messages from canonical resources" do
    for ui <- [A2ui.CanonicalPartyUI, A2ui.CanonicalContractUI, A2ui.CanonicalCommitmentUI] do
      messages = AshA2ui.Info.build_surface(ui)

      assert messages != []
      assert Enum.all?(messages, &is_map/1)

      refute AshA2ui.Info.resource!(ui) in [
               AshEnterprise.Legacy.User,
               AshEnterprise.Accounts.ProjectedUser
             ]
    end
  end

  test "canonical helper exposes only canonical read tools" do
    tools = AshAi.Info.tools(CanonicalAgent)

    assert Enum.sort(Enum.map(tools, &to_string(&1.name))) == Enum.sort(@canonical_names)
    assert Enum.all?(tools, &(&1.action == :read))
    assert Enum.all?(tools, &String.starts_with?(to_string(&1.name), "canonical_"))
  end

  test "canonical surfaces subscribe to their canonical resource publications" do
    surfaces = Enum.filter(Surfaces.all(), &String.starts_with?(&1.name, "canonical_"))

    assert Enum.map(surfaces, &Surfaces.topics/1) == [
             [
               "canonical_parties:created",
               "canonical_parties:updated",
               "canonical_parties:destroyed"
             ],
             [
               "canonical_contracts:created",
               "canonical_contracts:updated",
               "canonical_contracts:destroyed"
             ],
             [
               "canonical_commitments:created",
               "canonical_commitments:updated",
               "canonical_commitments:destroyed"
             ]
           ]
  end
end
