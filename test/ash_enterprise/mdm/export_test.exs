defmodule AshEnterprise.Mdm.ExportTest do
  @moduledoc """
  Egress (MDM-6): the active `:egress` mapping turns golden records into
  customer-shaped rows, and the zone disclosure gate refuses a departure on
  the residency tags recorded at land — never on caller input.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Mdm.TestSupport

  alias AshEnterprise.Canonical.Person
  alias AshEnterprise.Mdm.{ImportBatch, SourceIdentity}
  alias AshEnterprise.Platform.Seeder

  require Ash.Query

  setup do
    # The example declaration is the test's destination zone: CA-ON, ceiling
    # customer_confidential, US-restricted data inadmissible.
    previous = Application.get_env(:ash_enterprise, AshEnterprise.Zones)

    Application.put_env(:ash_enterprise, AshEnterprise.Zones,
      declarations: [{:priv, "zones/examples/ontario.json"}]
    )

    on_exit(fn ->
      if previous, do: Application.put_env(:ash_enterprise, AshEnterprise.Zones, previous)
    end)

    %{organization: organization, user: admin} =
      Seeder.seed_tenant(
        name: "Export #{System.unique_integer([:positive])}",
        unique_name: "export-#{System.unique_integer([:positive])}"
      )

    %{org: organization.id, admin: admin}
  end

  defp egress_mapping!(org, admin) do
    # Egress direction: path is the golden attribute, target the customer's
    # field — the mapping reads backwards, which is the no-deploy egress.
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

  # The real land path: Landing stamps residency_tag from the region.
  defp golden_via_land!(org, admin, name, email, region) do
    {:ok, record} =
      AshEnterprise.Mdm.Landing.land_row(
        org,
        "acme",
        %{"Full Name" => name, "Email" => email},
        region: region,
        row_key: "exp-#{System.unique_integer([:positive])}"
      )

    mapping = activate_host_mapping!(draft_host_mapping!(org, []), org, admin)

    batch =
      ImportBatch
      |> Ash.Changeset.for_create(:open, %{mapping_id: mapping.id, source_slug: "acme"},
        tenant: org,
        actor: admin
      )
      |> Ash.create!(tenant: org, actor: admin)

    staged =
      AshEnterprise.Mdm.StagedRecord
      |> Ash.Changeset.for_create(:stage, %{
        batch_id: batch.id,
        source_record_id: record.id,
        mapped: %{"name" => name, "email" => email}
      })
      |> Ash.create!(tenant: org, authorize?: false)

    golden =
      AshEnterprise.Canonical.Person
      |> Ash.Changeset.for_create(:upsert_from_source, %{
        name: name,
        email: email,
        owner_id: admin.id,
        owning_business_unit_id: admin.owning_business_unit_id
      })
      |> Ash.create!(tenant: org, authorize?: false)

    # The promotion's identity opening, done directly: the golden's residency
    # derives from the SourceRecord this identity points at.
    SourceIdentity
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

    {golden, staged}
  end

  test "a golden exports in the customer's shape through the zone gate", %{org: org, admin: admin} do
    egress_mapping!(org, admin)
    {_golden, _staged} = golden_via_land!(org, admin, "Ann Exported", "ann@x.io", "CA")

    assert {:ok, [%{"Email Address" => "ann@x.io", "Customer Name" => "Ann Exported"}]} =
             Person.mdm_export("example-ontario", tenant: org, actor: admin)
  end

  test "US-landed data cannot leave to the Ontario zone, whoever asks", %{org: org, admin: admin} do
    egress_mapping!(org, admin)
    {golden, _staged} = golden_via_land!(org, admin, "Ann Domestic", "ann@x.io", "US")
    id = golden.id

    assert {:error, %Ash.Error.Forbidden{errors: [forbidden]}} =
             Person.mdm_export("example-ontario", tenant: org, actor: admin)

    assert forbidden.custom_message =~ id
  end

  test "an actor without grants is refused before any data moves", %{org: org, admin: admin} do
    egress_mapping!(org, admin)
    golden_via_land!(org, admin, "Ann Exported", "ann@x.io", "CA")

    # No actor at all: the grant union has nothing to answer with, and the
    # RoleGrant filter check refuses by narrowing to zero rows.
    assert {:error, %Ash.Error.Forbidden{}} =
             Person.mdm_export("example-ontario", tenant: org)
  end
end
