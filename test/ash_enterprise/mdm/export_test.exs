defmodule AshEnterprise.Mdm.ExportTest do
  @moduledoc """
  Egress (MDM-6): the active `:egress` mapping turns golden records into
  customer-shaped rows, and the zone disclosure gate refuses a departure on
  the residency tags recorded at land — never on caller input.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Mdm.TestSupport

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Canonical.Person
  alias AshEnterprise.Mdm.{Egress, ImportBatch, SourceIdentity}
  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Security
  alias AshEnterprise.Security.ActorContext

  require Ash.Query

  setup do
    # The example declaration is the test's destination zone: CA-ON, ceiling
    # customer_confidential, US-restricted data inadmissible.
    previous = Application.get_env(:ash_enterprise, AshEnterprise.Zones)

    Application.put_env(:ash_enterprise, AshEnterprise.Zones,
      declarations: [{:priv, "zones/examples/ontario.json"}]
    )

    on_exit(fn ->
      # When there was no previous declaration (the default), the leak fix
      # is DELETION, not re-putting the absent value as a present one.
      if previous do
        Application.put_env(:ash_enterprise, AshEnterprise.Zones, previous)
      else
        Application.delete_env(:ash_enterprise, AshEnterprise.Zones)
      end
    end)

    %{organization: organization, user: admin, role: role, business_unit: business_unit} =
      Seeder.seed_tenant(
        name: "Export #{System.unique_integer([:positive])}",
        unique_name: "export-#{System.unique_integer([:positive])}"
      )

    %{org: organization.id, admin: admin, role: role, business_unit: business_unit}
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
    {_golden, _staged} = golden_via_land!(org, admin, "Ann Exported", "ann@x.io", :ca)

    assert {:ok, [%{"Email Address" => "ann@x.io", "Customer Name" => "Ann Exported"}]} =
             Egress.export("example-ontario", tenant: org, actor: admin)
  end

  test "US-landed data cannot leave to the Ontario zone, whoever asks", %{org: org, admin: admin} do
    egress_mapping!(org, admin)
    {golden, _staged} = golden_via_land!(org, admin, "Ann Domestic", "ann@x.io", :us)
    id = golden.id

    assert {:error, %Ash.Error.Forbidden{errors: [forbidden]}} =
             Egress.export("example-ontario", tenant: org, actor: admin)

    assert forbidden.custom_message =~ id
  end

  test "a merged loser is not exported", %{org: org, admin: admin} do
    egress_mapping!(org, admin)
    {golden, _staged} = golden_via_land!(org, admin, "Ann Kept", "kept@x.io", :ca)

    loser =
      AshEnterprise.Canonical.Person
      |> Ash.Changeset.for_create(:upsert_from_source, %{
        name: "Ann Lost",
        email: "lost@x.io",
        owner_id: admin.id,
        owning_business_unit_id: admin.owning_business_unit_id
      })
      |> Ash.create!(tenant: org, authorize?: false)
      |> then(fn loser ->
        loser
        |> Ash.Changeset.for_update(:mdm_merge_into, %{survivor_id: golden.id},
          tenant: org,
          authorize?: false
        )
        |> Ash.update!(tenant: org, authorize?: false)
      end)

    assert {:ok, rows} = Egress.export("example-ontario", tenant: org, actor: admin)

    # The survivor is there; the absorbed loser is not.
    assert length(rows) == 1
    assert hd(rows)["Email Address"] == "kept@x.io"
  end

  test "mixed-residency goldens refuse the export whole", %{org: org, admin: admin} do
    egress_mapping!(org, admin)
    golden_via_land!(org, admin, "Ann Domestic", "domestic@x.io", :ca)
    golden_via_land!(org, admin, "Ann Foreign", "foreign@x.io", :us)

    # One inadmissible golden refuses the export WHOLE: a partial export
    # would leak the presence of the rows it withheld. The mixed-residency
    # golden takes the union tag, which no single-region admission matches.
    assert {:error, %Ash.Error.Forbidden{errors: [forbidden]}} =
             Egress.export("example-ontario", tenant: org, actor: admin)

    assert forbidden.custom_message =~ "cannot leave"
  end

  test "one golden fed by CA and US identities is refused on the US tag", %{
    org: org,
    admin: admin
  } do
    egress_mapping!(org, admin)

    golden =
      AshEnterprise.Canonical.Person
      |> Ash.Changeset.for_create(:upsert_from_source, %{
        name: "Ann Mixed",
        email: "mixed@x.io",
        owner_id: admin.id,
        owning_business_unit_id: admin.owning_business_unit_id
      })
      |> Ash.create!(tenant: org, authorize?: false)

    for region <- [:ca, :us] do
      {:ok, record} =
        AshEnterprise.Mdm.Landing.land_row(
          org,
          "acme",
          %{"Full Name" => "Ann Mixed", "Email" => "mixed@x.io"},
          region: region,
          row_key: "mixed-#{region}-#{System.unique_integer([:positive])}"
        )

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
    end

    identities =
      AshEnterprise.Mdm.SourceIdentity
      |> Ash.Query.filter(golden_id == ^golden.id)
      |> Ash.read!(tenant: org, authorize?: false)

    assert length(identities) == 2, "identities=\#{length(identities)} golden=\#{golden.id}"

    # The US identity alone forbids the departure — the CA one cannot
    # outvote it.
    assert {:error, %Ash.Error.Forbidden{}} =
             Egress.export("example-ontario", tenant: org, actor: admin)
  end

  test "an actor without grants is refused before any data moves", %{org: org, admin: admin} do
    egress_mapping!(org, admin)
    golden_via_land!(org, admin, "Ann Exported", "ann@x.io", :ca)

    # No actor at all: the grant union has nothing to answer with, and the
    # RoleGrant filter check refuses by narrowing to zero rows.
    assert {:error, %Ash.Error.Forbidden{}} =
             Egress.export("example-ontario", tenant: org)
  end

  describe "the egress grant (ADR 0054, addendum 2026-10-16)" do
    test "a person holding every Administrator grant but egress is refused", ctx do
      egress_mapping!(ctx.org, ctx.admin)
      golden_via_land!(ctx.org, ctx.admin, "Ann Exported", "ann@x.io", :ca)

      # Every privilege the Administrator holds, Person and the MDM resources
      # included, minus the one egress privilege: no other grant stands in
      # for it.
      bob = member!(ctx, "bob", role_without_egress!(ctx))

      refute Ash.can?({Egress, :export}, actor(bob, ctx.org), tenant: ctx.org)

      assert {:error, %Ash.Error.Forbidden{}} =
               Egress.export("example-ontario", tenant: ctx.org, actor: actor(bob, ctx.org))
    end

    test "the egress grant exports the goldens and still reads no Person row", ctx do
      egress_mapping!(ctx.org, ctx.admin)
      {golden, _staged} = golden_via_land!(ctx.org, ctx.admin, "Ann Exported", "ann@x.io", :ca)

      carol = member!(ctx, "carol", role_with_only_egress!(ctx))
      steward = actor(carol, ctx.org)

      assert {:ok, [%{"Email Address" => "ann@x.io", "Customer Name" => "Ann Exported"}]} =
               Egress.export("example-ontario", tenant: ctx.org, actor: steward)

      # Person stays owner-only: the golden is the admin's row, and the
      # steward who exported it cannot read it.
      assert Person
             |> Ash.Query.for_read(:read, %{}, actor: steward, tenant: ctx.org)
             |> Ash.read!() == []

      refute Ash.can?({golden, :read}, steward, tenant: ctx.org)
    end

    test "a grant held in another tenant does not export this one", ctx do
      egress_mapping!(ctx.org, ctx.admin)
      golden_via_land!(ctx.org, ctx.admin, "Ann Exported", "ann@x.io", :ca)

      %{user: other_admin} =
        Seeder.seed_tenant(
          name: "Export elsewhere #{System.unique_integer([:positive])}",
          unique_name: "export-elsewhere-#{System.unique_integer([:positive])}",
          email: "elsewhere-#{System.unique_integer([:positive])}@export.synthetic.test"
        )

      assert {:error, %Ash.Error.Forbidden{errors: [forbidden]}} =
               Egress.export("example-ontario", tenant: ctx.org, actor: other_admin)

      assert forbidden.custom_message =~ "its own tenant only"
    end

    test "the egress privilege is grantable at :global only, and Person stays :basic only" do
      egress = privilege!(Egress, :read)
      assert egress.can_be_global
      refute egress.can_be_basic or egress.can_be_local or egress.can_be_deep

      person = privilege!(Person, :read)
      assert person.can_be_basic
      refute person.can_be_global or person.can_be_deep or person.can_be_local
    end
  end

  # -- grant helpers -----------------------------------------------------------

  defp privilege!(resource, verb) do
    name = inspect(resource)

    Security.Privilege
    |> Ash.Query.filter(resource_name == ^name and access_right == ^verb)
    |> Ash.read_one!(authorize?: false)
  end

  defp role_without_egress!(ctx) do
    egress = privilege!(Egress, :read)

    held =
      Security.RolePrivilege
      |> Ash.Query.filter(role_id == ^ctx.role.id and privilege_id != ^egress.id)
      |> Ash.read!(tenant: ctx.org, authorize?: false)

    role!(ctx, "Everything but egress", Enum.map(held, &{&1.privilege_id, &1.depth}))
  end

  defp role_with_only_egress!(ctx) do
    role!(ctx, "Data steward", [{privilege!(Egress, :read).id, :global}])
  end

  defp role!(ctx, name, grants) do
    role =
      Security.Role
      |> Ash.Changeset.for_create(
        :create,
        %{name: name, owning_business_unit_id: ctx.business_unit.id},
        tenant: ctx.org,
        authorize?: false
      )
      |> Ash.create!()

    for {privilege_id, depth} <- grants do
      Security.RolePrivilege
      |> Ash.Changeset.for_create(
        :create,
        %{role_id: role.id, privilege_id: privilege_id, depth: depth},
        tenant: ctx.org,
        authorize?: false
      )
      |> Ash.create!()
    end

    role
  end

  defp member!(ctx, name, role) do
    user =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "#{name}-#{System.unique_integer([:positive])}@export.synthetic.test",
          password: "password1234",
          password_confirmation: "password1234"
        },
        authorize?: false
      )
      |> Ash.create!()
      |> Ash.Changeset.for_update(
        :assign_to_business_unit,
        %{owning_business_unit_id: ctx.business_unit.id},
        authorize?: false
      )
      |> Ash.update!()

    Security.UserRole
    |> Ash.Changeset.for_create(
      :assign,
      %{user_id: user.id, role_id: role.id, scoping_business_unit_id: ctx.business_unit.id},
      tenant: ctx.org,
      authorize?: false
    )
    |> Ash.create!()

    user
  end

  defp actor(user, org), do: ActorContext.attach(user, ActorContext.build(user, tenant: org))
end
