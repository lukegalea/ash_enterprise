defmodule AshEnterprise.Mdm.LineageTest do
  @moduledoc """
  Plan §13.2: "where did this golden record come from" answered on all five
  §11 surfaces at once, for one completed import:

  1. SourceIdentity XREF — who asserted the link (the mapping, or a steward).
  2. The steward verdict's ledger rows — the person's recorded judgment.
  3. Audit events threaded by the batch's correlation id.
  4. The batch's pinned mapping content hash — lineage to the exact
     mapping version that produced the run.
  5. OpenLineage run events — run_id == correlation_id.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Mdm.TestSupport

  alias AshEnterprise.Mdm.{ImportBatch, MatchCandidate, SourceIdentity, SourceRecord}
  alias AshEnterprise.Platform.Seeder

  require Ash.Query

  setup do
    previous_transport = Application.get_env(:ash_open_lineage, :transport)

    Application.put_env(:ash_open_lineage, :transport, AshOpenLineage.Transport.InMemory)
    start_supervised!(AshOpenLineage.Transport.InMemory)

    on_exit(fn ->
      if previous_transport do
        Application.put_env(:ash_open_lineage, :transport, previous_transport)
      else
        Application.delete_env(:ash_open_lineage, :transport)
      end
    end)

    AshOpenLineage.Transport.InMemory.clear()

    Seeder.seed_platform_organization()
    AshEnterprise.Mdm.Banding.publish_seed_bands!(platform_org())

    publish_steward_definition()

    %{organization: organization, user: admin} =
      Seeder.seed_tenant(
        name: "Lineage #{System.unique_integer([:positive])}",
        unique_name: "lineage-#{System.unique_integer([:positive])}"
      )

    %{org: organization.id, admin: admin}
  end

  defp platform_org, do: Seeder.seed_platform_organization().id

  defp publish_steward_definition do
    alias AshEnterprise.Bpmn.Definition

    xml = File.read!("priv/bpmn/mdm_steward_review.bpmn")

    definition =
      Definition.create!(%{key: "mdm.steward_review", name: "MDM steward review", xml: xml},
        actor: AshEnterprise.Platform.SystemActor.process(),
        tenant: platform_org()
      )

    Definition.publish!(definition,
      actor: AshEnterprise.Platform.SystemActor.process(),
      tenant: platform_org()
    )
  end

  defp seed_rule_set!(org, admin) do
    rules = [
      %{"name" => "email_exact", "kind" => "exact", "fields" => ["email"], "weight" => 1.0},
      %{
        "name" => "name_fuzzy",
        "kind" => "fuzzy",
        "field" => "name",
        "algorithm" => "levenshtein",
        "weight" => 0.5
      }
    ]

    AshEnterprise.Mdm.MatchRuleSet
    |> Ash.Changeset.for_create(:draft, %{
      golden_resource: "AshEnterprise.Canonical.Person",
      rules: rules
    })
    |> Ash.create!(tenant: org, authorize?: false)
    |> Ash.Changeset.for_update(:activate, %{}, tenant: org, actor: admin)
    |> Ash.update!(tenant: org, actor: admin)
  end

  test "the completed import answers 'where did this golden come from' on all five surfaces", %{
    org: org,
    admin: admin
  } do
    seed_rule_set!(org, admin)

    AshEnterprise.Canonical.Person
    |> Ash.Changeset.for_create(:upsert_from_source, %{
      name: "Ann Existing",
      email: "ann@x.io",
      owner_id: admin.id,
      owning_business_unit_id: admin.owning_business_unit_id
    })
    |> Ash.create!(tenant: org, authorize?: false)

    for {key, payload} <- [
          {"fuzzy", %{"Email" => "ann@x.io", "Full Name" => "Ann Existing-Smith"}},
          {"new", %{"Email" => "nadia@x.io", "Full Name" => "Nadia New"}}
        ] do
      {:ok, _} = AshEnterprise.Mdm.Landing.land_row(org, "acme", payload, row_key: key)
    end

    mapping = activate_host_mapping!(draft_host_mapping!(org, []), org, admin)

    batch =
      ImportBatch
      |> Ash.Changeset.for_create(:open, %{mapping_id: mapping.id, source_slug: "acme"},
        tenant: org,
        actor: admin
      )
      |> Ash.create!(tenant: org, actor: admin)

    {:ok, _} =
      %{"batch_id" => batch.id, "tenant" => batch.organization_id}
      |> AshEnterprise.Mdm.BatchWorker.new()
      |> Oban.insert()

    Oban.drain_queue(queue: :mdm, with_safety: false)
    Oban.drain_queue(queue: :bpmn, with_safety: false)

    candidate =
      MatchCandidate
      |> Ash.Query.filter(band == ^:review and status == ^:pending)
      |> Ash.read_one!(tenant: org, authorize?: false)

    assert candidate != nil

    candidate
    |> Ash.Changeset.for_update(:confirm, %{}, tenant: org, actor: admin)
    |> Ash.update!(tenant: org, actor: admin)

    # ── 1. SourceIdentity XREF ────────────────────────────────────────────

    merged_golden =
      AshEnterprise.Canonical.Person
      |> Ash.Query.filter(email == ^"ann@x.io")
      |> Ash.read_one!(tenant: org, authorize?: false)

    new_golden =
      AshEnterprise.Canonical.Person
      |> Ash.Query.filter(email == ^"nadia@x.io")
      |> Ash.read_one!(tenant: org, authorize?: false)

    steward_xref =
      SourceIdentity
      |> Ash.Query.filter(golden_id == ^merged_golden.id)
      |> Ash.read!(tenant: org, authorize?: false)

    # The steward's confirm asserted the survivor link — the mapping alone
    # did not decide this golden's membership.
    assert steward_xref != []
    assert Enum.any?(steward_xref, &(&1.asserted_by == :steward))

    mapping_xref =
      SourceIdentity
      |> Ash.Query.filter(golden_id == ^new_golden.id)
      |> Ash.read!(tenant: org, authorize?: false)

    assert mapping_xref != []
    assert Enum.all?(mapping_xref, &(&1.asserted_by == :mapping))

    # ── 2. The verdict's ledger rows ──────────────────────────────────────

    decided = Ash.get!(MatchCandidate, candidate.id, tenant: org, authorize?: false)

    verdict =
      AshEnterprise.SystemOne.HumanVerdict
      |> Ash.Query.filter(id == ^decided.human_verdict_ref["verdict_id"])
      |> Ash.read_one!(tenant: org, authorize?: false)

    assert verdict.reviewer == to_string(admin.email)

    judgment =
      AshEnterprise.SystemOne.Judgment
      |> Ash.Query.filter(id == ^decided.human_verdict_ref["judgment_id"])
      |> Ash.read_one!(tenant: org, authorize?: false)

    assert judgment.subject_id == candidate.id

    # ── 3. Audit events under the correlation id ──────────────────────────

    %{rows: [[audited]]} =
      AshEnterprise.Repo.query!(
        "SELECT count(*) FROM audit_events " <>
          "WHERE metadata->>'correlation_id' = $1",
        [batch.correlation_id]
      )

    # The survivor write, the staged row's merge write and the batch's own
    # transitions all carry the one correlation id.
    assert audited > 0

    # ── 4. The pinned mapping version ─────────────────────────────────────

    reloaded =
      Ash.get!(AshEnterprise.Mdm.Mapping, mapping.id, tenant: org, authorize?: false)

    assert batch.mapping_content_hash == reloaded.content_hash

    for key <- ["fuzzy", "new"] do
      assert SourceRecord
             |> Ash.Query.filter(external_id == ^"#{org}:acme:#{key}")
             |> Ash.exists?(tenant: org, authorize?: false)
    end

    # ── 5. OpenLineage run events ─────────────────────────────────────────

    events = AshOpenLineage.Transport.InMemory.events()

    for lineage_event <- events do
      if lineage_event["run"]["runId"] == batch.correlation_id do
        assert lineage_event["eventType"] in ["START", "COMPLETE"]
      end
    end

    runs = Enum.map(events, & &1["run"]["runId"])
    assert batch.correlation_id in runs
    assert length(Enum.filter(events, &(&1["eventType"] == "START"))) >= 1
    assert length(Enum.filter(events, &(&1["eventType"] == "COMPLETE"))) >= 1
  end
end
