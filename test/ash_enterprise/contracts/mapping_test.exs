defmodule AshEnterprise.Contracts.MappingTest do
  use ExUnit.Case, async: true

  @compatibility_resources [
    AshEnterprise.Contracts.Party,
    AshEnterprise.Contracts.PartyFromVendor,
    AshEnterprise.Contracts.PartyFromEnterprise,
    AshEnterprise.Contracts.ContractingProcess,
    AshEnterprise.Contracts.PartyRole,
    AshEnterprise.Contracts.Contract,
    AshEnterprise.Contracts.ContractLine,
    AshEnterprise.Contracts.Commitment
  ]

  @greenfield_resources [
    AshEnterprise.Contracts.Amendment,
    AshEnterprise.Contracts.Milestone,
    AshEnterprise.Contracts.Transaction
  ]

  test "all legacy compatibility resources are complete strangler mappings" do
    for resource <- @compatibility_resources do
      assert AshStrangler.Info.strangled?(resource)
      assert AshStrangler.Info.strangler_phase!(resource) == :read_from_legacy

      attributes =
        resource
        |> Ash.Resource.Info.attributes()
        |> Enum.reject(&Map.get(&1, :private?, false))
        |> MapSet.new(& &1.name)

      assert AshStrangler.Info.accounted_for(resource) == attributes
    end
  end

  test "each compatibility mapping states every read-only limitation" do
    for resource <- @compatibility_resources do
      for mapping <- AshStrangler.Info.mappings(resource) do
        if Map.get(mapping, :read_only?, false) do
          assert is_binary(mapping.because)
          assert String.trim(mapping.because) != ""
        end
      end
    end
  end

  test "the canonical resource set includes greenfield gaps" do
    resources = Ash.Domain.Info.resources(AshEnterprise.Contracts)

    assert Enum.all?(@compatibility_resources ++ @greenfield_resources, &(&1 in resources))
    assert Enum.all?(@greenfield_resources, &(not AshStrangler.Info.strangled?(&1)))
  end
end