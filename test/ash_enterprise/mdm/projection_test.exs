defmodule AshEnterprise.Mdm.ProjectionTest do
  @moduledoc """
  The replay determinism contract (MDM-5): delete the goldens, replay from
  SourceRecords + the active mapping + the identity history, and the rows
  come back byte-identical. Merge state (merged/master_id) is deliberately
  not resurrected.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Mdm.TestSupport

  require Ash.Query

  alias AshEnterprise.Canonical.Person
  alias AshEnterprise.Mdm.Projection

  setup do
    %{organization: organization, user: admin} =
      AshEnterprise.Platform.Seeder.seed_tenant(
        name: "Replay #{System.unique_integer([:positive])}",
        unique_name: "replay-#{System.unique_integer([:positive])}"
      )

    %{org: organization.id, admin: admin}
  end

  test "deleting the goldens and replaying rebuilds them identically", %{org: org, admin: admin} do
    mapping = activate_host_mapping!(draft_host_mapping!(org, []), org, admin)

    {:ok, record} =
      AshEnterprise.Mdm.Landing.land_row(
        org,
        "acme",
        %{"Full Name" => "Rita Replay", "Email" => "rita@x.io"},
        row_key: "replay-1"
      )

    # The pipeline's promotion: stage, confirm into a golden (which opens
    # the identity), so the identity history is the recorded decision.
    staged =
      AshEnterprise.Mdm.StagedRecord
      |> Ash.Changeset.for_create(:stage, %{
        batch_id: Ash.UUID.generate(),
        source_record_id: record.id,
        mapped: %{"name" => "Rita Replay", "email" => "rita@x.io"}
      })
      |> Ash.create!(tenant: org, authorize?: false)

    golden =
      AshEnterprise.Canonical.Person
      |> Ash.Changeset.for_create(:upsert_from_source, %{
        name: "Rita Replay",
        email: "rita@x.io",
        owner_id: admin.id,
        owning_business_unit_id: admin.owning_business_unit_id
      })
      |> Ash.create!(tenant: org, authorize?: false)

    AshEnterprise.Mdm.SourceIdentity
    |> Ash.Changeset.for_create(
      :open,
      %{
        source: to_string(record.source),
        stream: to_string(record.stream),
        external_id: record.external_id,
        golden_resource: "AshEnterprise.Canonical.Person",
        golden_id: golden.id,
        asserted_by: :steward
      },
      tenant: org,
      authorize?: false
    )
    |> Ash.create!(tenant: org, authorize?: false)

    before =
      Person
      |> Ash.Query.sort(email: :asc)
      |> Ash.read!(tenant: org, authorize?: false)
      |> Enum.map(&{&1.email, &1.name})

    # Delete every golden; the mapping is still active and the identity
    # history still records the decision.
    AshEnterprise.Repo.query!("DELETE FROM canonical_people", [])

    assert {:ok, 1} = Projection.replay(tenant: org)

    after_replay =
      Person
      |> Ash.Query.sort(email: :asc)
      |> Ash.read!(tenant: org, authorize?: false)
      |> Enum.map(&{&1.email, &1.name, &1.merged, &1.master_id, &1.id})

    assert [{email, name, false, nil, id}] = after_replay

    # The id is PINNED from the identity history: the XREF still resolves,
    # and the pre-replay row is the same row.
    assert id == golden.id
    assert {email, name} == Enum.find(before, fn {e, _} -> to_string(e) == "rita@x.io" end)

    reloaded = Ash.get!(Person, golden.id, tenant: org, authorize?: false)
    assert reloaded.owner_id == admin.id
    assert to_string(email) == "rita@x.io"
    assert name == "Rita Replay"
    assert length(before) >= 1

    # Replay is deterministic: delete + replay again, same rows.
    AshEnterprise.Repo.query!("DELETE FROM canonical_people", [])
    assert {:ok, 1} = Projection.replay(tenant: org)

    second =
      Person
      |> Ash.Query.sort(email: :asc)
      |> Ash.read!(tenant: org, authorize?: false)
      |> Enum.map(&{&1.email, &1.name, &1.merged, &1.master_id, &1.id})

    assert after_replay == second
    assert mapping.status == :active
  end
end
