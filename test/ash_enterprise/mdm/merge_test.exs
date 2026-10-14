defmodule AshEnterprise.Mdm.MergeTest do
  @moduledoc """
  MDM-5: the merge write — survivorship picks per-attribute winners, the
  loser survives pointing at the survivor, SourceIdentity periods repoint,
  and the whole thing audits under ONE correlation id. The unmerge
  correction restores the loser.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Mdm.TestSupport

  alias AshEnterprise.Mdm.SourceIdentity
  alias AshEnterprise.Platform.Seeder

  setup do
    %{organization: org, user: admin} =
      Seeder.seed_tenant(
        name: "Mdm Merge #{System.unique_integer([:positive])}",
        unique_name: "mdm-merge-#{System.unique_integer([:positive])}"
      )

    Seeder.seed_platform_organization()

    %{org: org.id, admin: admin}
  end

  defp golden!(org, admin, name, email) do
    AshEnterprise.Canonical.Person
    |> Ash.Changeset.for_create(:upsert_from_source, %{
      name: name,
      email: email,
      owner_id: admin.id,
      owning_business_unit_id: admin.owning_business_unit_id
    })
    |> Ash.create!(tenant: org, authorize?: false)
  end

  defp identity!(org, external_id, golden) do
    SourceIdentity
    |> Ash.Changeset.for_create(:open, %{
      source: :manual_csv,
      stream: :upload,
      external_id: external_id,
      golden_resource: "AshEnterprise.Canonical.Person",
      golden_id: golden.id,
      asserted_by: :mapping
    })
    |> Ash.create!(tenant: org, authorize?: false)
  end

  test "merge: survivorship fills nils, loser points at survivor, XREF repoints", %{
    org: org,
    admin: admin
  } do
    survivor = golden!(org, admin, "Ann Existing", nil)
    loser = golden!(org, admin, nil, "ann@x.io")

    ident = identity!(org, "ext-1", loser)

    loser
    |> Ash.Changeset.for_update(:mdm_merge_into, %{survivor_id: survivor.id},
      tenant: org,
      authorize?: false
    )
    |> Ash.update!(tenant: org, authorize?: false)

    reloaded_loser = Ash.reload!(loser, tenant: org, authorize?: false)
    reloaded_survivor = Ash.reload!(survivor, tenant: org, authorize?: false)

    # Non-destructive by construction: the loser's row survives, pointing.
    assert reloaded_loser.merged == true
    assert reloaded_loser.master_id == survivor.id

    # Survivorship non_null: the survivor gained the email it lacked.
    assert to_string(reloaded_survivor.email) == "ann@x.io"
    assert reloaded_survivor.merged == false

    # The XREF repointed at the survivor: one current identity, new golden.
    {:ok, current} =
      SourceIdentity.current_for(ident.source, ident.stream, ident.external_id,
        tenant: org,
        authorize?: false
      )

    assert current
    assert current.golden_id == survivor.id
  end

  test "unmerge: the loser stands alone again", %{org: org, admin: admin} do
    survivor = golden!(org, admin, "Ann Existing", "ann@x.io")
    loser = golden!(org, admin, "Ann Duplicate", "ann2@x.io")

    loser =
      loser
      |> Ash.Changeset.for_update(:mdm_merge_into, %{survivor_id: survivor.id},
        tenant: org,
        authorize?: false
      )
      |> Ash.update!(tenant: org, authorize?: false)

    unmerged =
      loser
      |> Ash.Changeset.for_update(:mdm_unmerge, %{}, tenant: org, authorize?: false)
      |> Ash.update!(tenant: org, authorize?: false)

    assert unmerged.merged == false
    assert unmerged.master_id == nil
    assert unmerged.name == "Ann Duplicate"
  end

  test "a record cannot merge into itself", %{org: org, admin: admin} do
    p = golden!(org, admin, "Solo", "solo@x.io")

    assert {:error, %Ash.Error.Invalid{}} =
             p
             |> Ash.Changeset.for_update(:mdm_merge_into, %{survivor_id: p.id},
               tenant: org,
               authorize?: false
             )
             |> Ash.update(tenant: org, authorize?: false)
  end
end
