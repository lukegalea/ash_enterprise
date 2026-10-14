defmodule AshEnterprise.Mdm.CsImportFlowTest do
  @moduledoc """
  The flagship flow end to end (plan §9): a CS person receives new customer
  records → imports (land → batch → stage → match → band) → confirms the
  low-confidence match in the steward queue → the import completes
  (golden merged, identity opened) → the merged golden exports in the
  customer's shape, and the whole flow answers "where did this row come
  from" through one correlation id.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AshEnterprise.Mdm.TestSupport

  alias AshEnterprise.Mdm.{ImportBatch, SourceIdentity, StagedRecord}
  alias AshEnterprise.Platform.Seeder

  require Ash.Query

  setup %{conn: conn} do
    Seeder.seed_platform_organization()
    AshEnterprise.Mdm.Banding.publish_seed_bands!(platform_org())

    # The review process baseline: the steward task ledger side.
    publish_steward_definition()

    %{organization: organization, user: admin} =
      Seeder.seed_tenant(
        name: "CS Flow #{System.unique_integer([:positive])}",
        unique_name: "cs-flow-#{System.unique_integer([:positive])}"
      )

    # The destination zone for the export leg (same declaration the export
    # tests use; restored after — absent config is deleted, not re-put).
    previous = Application.get_env(:ash_enterprise, AshEnterprise.Zones)

    Application.put_env(:ash_enterprise, AshEnterprise.Zones,
      declarations: [{:priv, "zones/examples/ontario.json"}]
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:ash_enterprise, AshEnterprise.Zones, previous)
      else
        Application.delete_env(:ash_enterprise, AshEnterprise.Zones)
      end
    end)

    %{conn: sign_in(conn, admin), org: organization.id, admin: admin}
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

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
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
    |> then(fn rule_set ->
      rule_set
      |> Ash.Changeset.for_update(:activate, %{}, tenant: org, actor: admin)
      |> Ash.update!(tenant: org, actor: admin)
    end)
  end

  test "import → match → steward confirm → merged golden exports", %{
    conn: conn,
    org: org,
    admin: admin
  } do
    egress_mapping!(org, admin)
    seed_rule_set!(org, admin)

    # The CS person's existing customer and one new upload row that fuzzy-
    # matches it (the seed's review band), plus one genuinely new row.
    golden_person!(org, admin, "Ann Existing", "ann@x.io")

    for {key, payload} <- [
          {"fuzzy", %{"Email" => "ann@x.io", "Full Name" => "Ann Existing-Smith"}},
          {"new", %{"Email" => "nadia@x.io", "Full Name" => "Nadia New"}}
        ] do
      # A Canadian deployment: rows land CA-tagged, so the Ontario export
      # zone admits them at departure.
      {:ok, _} =
        AshEnterprise.Mdm.Landing.land_row(org, "acme", payload, row_key: key, region: :ca)
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

    # The review-banded candidate is claimable work in the queue.
    candidate =
      AshEnterprise.Mdm.MatchCandidate
      |> Ash.Query.filter(band == ^:review and status == ^:pending)
      |> Ash.read_one!(tenant: org, authorize?: false)

    assert candidate != nil, "the fuzzy match awaits a steward"

    # The steward confirms through the queue's act.
    candidate
    |> Ash.Changeset.for_update(:confirm, %{}, tenant: org, actor: admin)
    |> Ash.update!(tenant: org, actor: admin)

    # Import completed for both rows: the confirmed one merged into the
    # golden; the genuinely new row became a golden of its own.
    merged_golden =
      AshEnterprise.Canonical.Person
      |> Ash.Query.filter(email == ^"ann@x.io")
      |> Ash.read_one!(tenant: org, authorize?: false)

    # Survivorship: the golden's own values win — the fuzzy variant did not
    # overwrite the existing customer.
    assert to_string(merged_golden.name) == "Ann Existing"
    assert merged_golden.merged == false

    new_golden =
      AshEnterprise.Canonical.Person
      |> Ash.Query.filter(email == ^"nadia@x.io")
      |> Ash.read_one!(tenant: org, authorize?: false)

    assert new_golden != nil

    # Every golden's provenance answers through the XREF.
    for golden <- [merged_golden, new_golden] do
      assert AshEnterprise.Mdm.SourceIdentity
             |> Ash.Query.filter(golden_id == ^golden.id)
             |> Ash.exists?(tenant: org, authorize?: false)
    end

    # One correlation id threads the flow: the batch's audit rows and the
    # stewardship instance share it.
    instance =
      AshEnterprise.Bpmn.Instance
      |> Ash.Query.filter(status == ^:completed)
      |> Ash.read!(tenant: org, authorize?: false)
      |> Enum.find(&(&1.subject_id == candidate.id))

    assert instance != nil
    assert instance.correlation_id == batch.correlation_id

    %{rows: [[review_events]]} =
      AshEnterprise.Repo.query!(
        "SELECT count(*) FROM audit_events " <>
          "WHERE metadata->>'correlation_id' = $1",
        [batch.correlation_id]
      )

    assert review_events > 0

    # The merged golden exports in the customer's shape through the zone
    # gate.
    egress_mapping!(org, admin)

    # Both goldens export, in the customer's shape, CA-admitted.
    assert {:ok, rows} =
             AshEnterprise.Canonical.Person.mdm_export("example-ontario",
               tenant: org,
               actor: admin
             )

    assert %{
             "Email Address" => "ann@x.io",
             "Customer Name" => "Ann Existing"
           } in rows

    assert %{
             "Email Address" => "nadia@x.io",
             "Customer Name" => "Nadia New"
           } in rows
  end

  defp egress_mapping!(org, admin) do
    org
    |> draft_host_mapping!(
      direction: :egress,
      field_rules: [
        %{"path" => "email", "target" => "Email Address", "op" => "identity", "args" => %{}},
        %{"path" => "name", "target" => "Customer Name", "op" => "identity", "args" => %{}},
        %{
          "path" => nil,
          "target" => "merged",
          "op" => "unmapped",
          "args" => %{},
          "because" => "internal merge state"
        },
        %{
          "path" => nil,
          "target" => "master_id",
          "op" => "unmapped",
          "args" => %{},
          "because" => "internal merge state"
        }
      ],
      observed_schema: %{"Email Address" => %{}, "Customer Name" => %{}}
    )
    |> activate_host_mapping!(org, admin)
  end

  defp golden_person!(org, admin, name, email) do
    AshEnterprise.Canonical.Person
    |> Ash.Changeset.for_create(:upsert_from_source, %{
      name: name,
      email: email,
      owner_id: admin.id,
      owning_business_unit_id: admin.owning_business_unit_id
    })
    |> Ash.create!(tenant: org, authorize?: false)
  end
end
