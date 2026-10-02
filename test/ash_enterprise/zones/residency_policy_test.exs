defmodule AshEnterprise.Zones.ResidencyPolicyTest do
  @moduledoc """
  The host's tenant disclosure policy, as assertions
  ([ADR 0042](../../../docs/adr/0042-in-zone-inference-leaving-the-zone-is-a-disclosure.md)).

  The interesting rows are the refusals: the default posture is that data
  stays in the zone, and every way of *not knowing* — no tenant, an
  unresolvable id, a residency class the host has not ruled on — lands on
  "no". A tenant opts into sub-processor inference only by a recorded
  `sub_processor_opt_in` on its organization row.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Accounts.Organization
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Zones.ResidencyPolicy

  defp create_organization! do
    Organization
    |> Ash.Changeset.for_create(
      :create,
      %{
        unique_name: "respol-#{System.unique_integer([:positive])}",
        name: "Residency policy probe"
      },
      actor: SystemActor.seed()
    )
    |> Ash.create!()
  end

  defp opt_in!(organization) do
    organization
    |> Ash.Changeset.for_update(:update, %{sub_processor_opt_in: true}, actor: SystemActor.seed())
    |> Ash.update!()
  end

  describe "in-cluster instruments" do
    test "are allowed with a tenant" do
      organization = create_organization!()
      assert ResidencyPolicy.allow?(organization.id, :in_cluster, :coi)
    end

    test "are allowed with no tenant at all" do
      # In-zone inference is the default, not a disclosure: there is nothing
      # for an absent tenant to opt into.
      assert ResidencyPolicy.allow?(nil, :in_cluster, nil)
    end
  end

  describe "sub-processor instruments" do
    test "are refused with no tenant" do
      refute ResidencyPolicy.allow?(nil, :sub_processor, :coi)
    end

    test "are refused when the tenant has not opted in" do
      organization = create_organization!()
      refute ResidencyPolicy.allow?(organization.id, :sub_processor, :coi)
    end

    test "are allowed only once the tenant's opt-in is recorded" do
      organization = create_organization!()
      refute ResidencyPolicy.allow?(organization.id, :sub_processor, :coi)

      opt_in!(organization)
      assert ResidencyPolicy.allow?(organization.id, :sub_processor, :coi)
    end

    test "accept the organization struct itself" do
      organization = opt_in!(create_organization!())
      assert ResidencyPolicy.allow?(organization, :sub_processor, :coi)
    end

    test "are refused for an unresolvable tenant id" do
      # A read failure is a refusal, never an open door.
      refute ResidencyPolicy.allow?(Ash.UUID.generate(), :sub_processor, :coi)
    end

    test "do not depend on the question family" do
      organization = opt_in!(create_organization!())
      assert ResidencyPolicy.allow?(organization.id, :sub_processor, :any_family)
    end
  end

  test "a residency class the host has not ruled on is refused" do
    # If the package ever grows a third class, the host must rule on it
    # before any tenant's data flows to it.
    refute ResidencyPolicy.allow?(nil, :some_future_class, :coi)
  end
end
