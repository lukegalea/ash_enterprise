defmodule AshEnterpriseWeb.A2ui.MdmRecordSurfacesTest do
  @moduledoc """
  The MDM record surfaces' details, read as a person: the golden record's
  detail with its source identities and merge history (and, for a merged
  record, the golden that absorbed it), the mapping version's detail with
  the version it supersedes, and the import-batch board with a batch's
  counts and staged rows. Person is owner-only, so the golden surface shows
  exactly the people the reader owns.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Mdm.TestSupport
  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  alias AshEnterprise.Canonical.Person
  alias AshEnterprise.Mdm.{ImportBatch, Mapping, MatchCandidate, SourceIdentity}
  alias AshEnterpriseWeb.A2ui.{MdmBatchUI, MdmGoldenUI, MdmMappingUI}

  setup do
    %{admin: tenant!()}
  end

  defp data_model(ui, person, selection) do
    state =
      AshA2ui.Info.context_state_for(ui, selection, actor: person.actor, tenant: person.tenant)

    %{"updateDataModel" => %{"value" => value}} =
      AshA2ui.Info.build_data_model(ui,
        actor: person.actor,
        tenant: person.tenant,
        context_state: state
      )

    value
  end

  defp identity!(tenant, golden, external_id) do
    SourceIdentity
    |> Ash.Changeset.for_create(
      :open,
      %{
        source: "manual_csv",
        stream: "upload",
        external_id: external_id,
        golden_resource: "AshEnterprise.Canonical.Person",
        golden_id: golden.id,
        asserted_by: :steward
      },
      tenant: tenant,
      authorize?: false
    )
    |> Ash.create!(tenant: tenant, authorize?: false)
  end

  describe "golden records" do
    setup %{admin: admin} do
      {candidate, _staged, golden} =
        staged_candidate!(admin.tenant, admin.user, "Ann Dup", "ann@example.test")

      identity!(admin.tenant, golden, "#{admin.tenant}:acme:ann")
      %{golden: golden, candidate: candidate}
    end

    test "a golden's detail shows its identities and merge history", %{
      admin: admin,
      golden: golden,
      candidate: candidate
    } do
      value = data_model(MdmGoldenUI, admin, %{"person" => golden.id})

      assert [%{"id" => id}] = value["records"]["table"]
      assert id == golden.id

      assert value["detail"]["person"]["name"] == "Ann Dup Existing"
      assert value["detail"]["person"]["absorbed_by"] in [nil, ""]

      assert [%{"external_id" => external_id}] = value["records"]["identities"]
      assert external_id =~ ":acme:ann"

      assert [%{"id" => history_id, "staged_label" => "Ann Dup"}] =
               value["records"]["merge_history"]

      assert history_id == candidate.id
    end

    test "a merged record links the golden that absorbed it", %{admin: admin, golden: golden} do
      loser =
        Person
        |> Ash.Changeset.for_create(:upsert_from_source, %{
          name: "Ann Absorbed",
          email: "absorbed@example.test",
          owner_id: admin.user.id,
          owning_business_unit_id: admin.user.owning_business_unit_id
        })
        |> Ash.create!(tenant: admin.tenant, authorize?: false)
        |> Ash.Changeset.for_update(:mdm_merge_into, %{survivor_id: golden.id},
          tenant: admin.tenant,
          authorize?: false
        )
        |> Ash.update!(tenant: admin.tenant, authorize?: false)

      detail = data_model(MdmGoldenUI, admin, %{"person" => loser.id})["detail"]["person"]

      assert detail["absorbed_by"] == "Ann Dup Existing"

      assert %{"surface" => "mdm_golden", "recordId" => survivor} =
               detail["_links"]["absorbed_by"]

      assert survivor == golden.id
    end

    test "shows a reader only the people they own", %{admin: admin, golden: golden} do
      reader =
        member!(admin, "Steward", [
          {Person, :read, :basic},
          {SourceIdentity, :read, :global},
          {MatchCandidate, :read, :global}
        ])

      value = data_model(MdmGoldenUI, reader, %{"person" => golden.id})

      assert value["records"]["table"] == []
      assert value["detail"]["person"] in [nil, %{}]
      assert value["records"]["identities"] in [nil, []]
    end
  end

  describe "mapping versions" do
    test "a version's detail shows its rules and links the version it supersedes", %{
      admin: admin
    } do
      first =
        activate_host_mapping!(draft_host_mapping!(admin.tenant, []), admin.tenant, admin.user)

      second =
        Mapping
        |> Ash.Changeset.for_create(
          :create_version,
          %{
            from_mapping_id: first.id,
            direction: :ingress,
            source: "manual_csv",
            stream: "acme_contacts",
            target_resource: "AshEnterprise.Canonical.Person",
            field_rules: person_rules(),
            observed_schema: %{"Email" => %{}, "Full Name" => %{}}
          },
          tenant: admin.tenant,
          authorize?: false
        )
        |> Ash.create!(tenant: admin.tenant, authorize?: false)

      detail = data_model(MdmMappingUI, admin, %{"mapping" => second.id})["detail"]["mapping"]

      assert detail["rule_summary"] =~ "Email → email (trim)"
      assert detail["previous_version"] == "Version 1"

      assert %{"surface" => "mdm_mappings", "recordId" => previous} =
               detail["_links"]["previous_version"]

      assert previous == first.id
    end
  end

  describe "import batches" do
    test "the board lanes batches by status; a batch's detail lists its staged rows", %{
      admin: admin
    } do
      {_candidate, staged, _golden} =
        staged_candidate!(admin.tenant, admin.user, "Ann Dup", "ann@example.test")

      batch = ImportBatch.by_id!(staged.batch_id, tenant: admin.tenant, authorize?: false)

      batch
      |> Ash.Changeset.for_update(:fail, %{failure_reason: "the file had no header row"},
        tenant: admin.tenant,
        authorize?: false
      )
      |> Ash.update!(tenant: admin.tenant, authorize?: false)

      value = data_model(MdmBatchUI, admin, %{"batch" => batch.id})

      lanes =
        for {lane, [_ | _] = rows} <- value["records"], do: {lane, Enum.map(rows, & &1["id"])}

      assert Enum.any?(lanes, fn {lane, ids} -> lane =~ "failed" and batch.id in ids end)

      detail = value["detail"]["batch"]
      assert detail["failure_reason"] == "the file had no header row"
      assert detail["source_slug"] == "acme_contacts"
      assert %{"surface" => "mdm_mappings"} = detail["_links"]["mapping"]

      assert [%{"id" => staged_id, "label" => "Ann Dup"}] = value["records"]["staged_rows"]
      assert staged_id == staged.id
    end

    test "a person without a grant on batches sees no batch and no staged row", %{admin: admin} do
      {_candidate, staged, _golden} =
        staged_candidate!(admin.tenant, admin.user, "Ann Dup", "ann@example.test")

      stranger = member!(admin, "No grants", [])
      value = data_model(MdmBatchUI, stranger, %{"batch" => staged.batch_id})

      assert value["records"] |> Map.values() |> Enum.filter(&is_list/1) |> List.flatten() == []
    end
  end
end
