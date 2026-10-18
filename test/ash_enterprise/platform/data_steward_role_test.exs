defmodule AshEnterprise.Platform.DataStewardRoleTest do
  @moduledoc """
  The starter Data Steward role (ADR 0054, addendum of 2026-10-17): seeded
  with every tenant, carrying the steward-queue grants and the MDM egress
  grant and nothing else; existing tenants receive it through
  `Seeder.regrant_data_steward/1`, which is a dry run unless told otherwise,
  additive, and idempotent.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Security

  setup do
    n = System.unique_integer([:positive])
    %{organization: org} = Seeder.seed_tenant(name: "DS #{n}", unique_name: "ds-#{n}")
    %{org: org.id, unique_name: "ds-#{n}"}
  end

  defp ash(org), do: [actor: SystemActor.seed(), tenant: org]

  defp steward_role(org) do
    Security.Role
    |> Ash.Query.filter(name == ^Seeder.data_steward_role())
    |> Ash.read_one!(ash(org))
  end

  defp grants(role, org) do
    Security.RolePrivilege
    |> Ash.Query.filter(role_id == ^role.id)
    |> Ash.Query.load(:privilege)
    |> Ash.read!(ash(org))
    |> MapSet.new(&{&1.privilege.resource_name, &1.privilege.access_right, &1.depth})
  end

  test "a new tenant has the role with exactly the steward grants, each at its widest depth",
       %{org: org} do
    role = steward_role(org)
    assert role

    assert grants(role, org) ==
             MapSet.new([
               {"AshEnterprise.Mdm.MatchCandidate", :read, :global},
               {"AshEnterprise.Mdm.MatchCandidate", :write, :global},
               {"AshEnterprise.Mdm.StagedRecord", :read, :global},
               {"AshEnterprise.Mdm.ImportBatch", :read, :global},
               {"AshEnterprise.Mdm.Mapping", :read, :global},
               {"AshEnterprise.Mdm.SourceIdentity", :read, :global},
               # Person is owner-only: a steward reads the goldens they own.
               {"AshEnterprise.Canonical.Person", :read, :basic},
               {"AshEnterprise.SystemOne.HumanVerdict", :create, :global},
               {"AshEnterprise.Mdm.Egress", :read, :global}
             ])

    # No task grant: stewards reach their tasks through candidacy.
    refute Enum.any?(grants(role, org), &match?({"AshEnterprise.Bpmn." <> _, _, _}, &1))
  end

  test "a 16-character unique_name is a name, not a raw uuid" do
    %{organization: org} = Seeder.seed_tenant(name: "Sixteen", unique_name: "e2e-steward-1605")

    assert [%{tenant: id}] = Seeder.regrant_data_steward(tenant: "e2e-steward-1605")
    assert id == org.id
  end

  test "the regrant is a dry run by default and writes nothing", %{org: org, unique_name: name} do
    role = steward_role(org)
    [missing | _] = role |> grants(org) |> Enum.sort()
    drop_grant!(role, missing, org)

    assert [%{role: :exists, dry_run?: true, added: [^missing]}] =
             Seeder.regrant_data_steward(tenant: name)

    refute MapSet.member?(grants(role, org), missing)
  end

  test "applied, it adds what is missing, once", %{org: org, unique_name: name} do
    role = steward_role(org)
    [missing | _] = role |> grants(org) |> Enum.sort()
    drop_grant!(role, missing, org)

    assert [%{role: :exists, added: [^missing]}] =
             Seeder.regrant_data_steward(tenant: org, dry_run?: false)

    assert MapSet.member?(grants(role, org), missing)

    assert [%{role: :exists, added: []}] =
             Seeder.regrant_data_steward(tenant: name, dry_run?: false)
  end

  test "a tenant without the role gets it created; nobody is assigned it", %{org: org} do
    # A tenant provisioned before the role existed: its role is named otherwise.
    steward_role(org)
    |> Ash.Changeset.for_update(:update, %{name: "Old stewards"}, ash(org))
    |> Ash.update!()

    assert %{role: :would_create, added: added} = Seeder.ensure_data_steward_role(org)
    assert length(added) == length(Seeder.data_steward_grants())
    refute steward_role(org)

    assert %{role: :created} = Seeder.ensure_data_steward_role(org, dry_run?: false)
    role = steward_role(org)
    assert MapSet.size(grants(role, org)) == length(Seeder.data_steward_grants())

    refute Security.UserRole
           |> Ash.Query.filter(role_id == ^role.id)
           |> Ash.exists?(ash(org))
  end

  defp drop_grant!(role, {resource_name, verb, _depth}, org) do
    Security.RolePrivilege
    |> Ash.Query.filter(
      role_id == ^role.id and privilege.resource_name == ^resource_name and
        privilege.access_right == ^verb
    )
    |> Ash.read_one!(ash(org))
    |> Ash.destroy!(ash(org))
  end
end
