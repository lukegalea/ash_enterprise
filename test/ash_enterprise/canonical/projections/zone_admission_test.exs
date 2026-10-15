defmodule AshEnterprise.Canonical.Projections.ZoneAdmissionTest do
  @moduledoc """
  The real zone gate (ADR 0042): a landed record is admitted iff its linked
  account's tags may enter the canonical store's declared zone.
  """

  use ExUnit.Case, async: false

  alias AshEnterprise.Canonical.Projections.ZoneAdmission

  @moduletag :tmp_dir

  @account_id "6f7c1a52-6d1e-4a0e-9a0f-2f1d7f0c9b11"

  setup ctx do
    previous =
      Map.new(
        [AshEnterprise.Zones, ZoneAdmission],
        &{&1, Application.get_env(:ash_enterprise, &1)}
      )

    on_exit(fn ->
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:ash_enterprise, key, value),
          else: Application.delete_env(:ash_enterprise, key)
      end
    end)

    today = Date.utc_today()

    in_force =
      declare(
        ctx.tmp_dir,
        "lab",
        "customer_confidential",
        Date.add(today, -1),
        Date.add(today, 30)
      )

    narrow = declare(ctx.tmp_dir, "narrow", "internal", Date.add(today, -1), Date.add(today, 30))

    lapsed =
      declare(
        ctx.tmp_dir,
        "lapsed",
        "customer_confidential",
        Date.add(today, -60),
        Date.add(today, -1)
      )

    Application.put_env(:ash_enterprise, AshEnterprise.Zones,
      declarations: [in_force, narrow, lapsed]
    )

    Application.put_env(:ash_enterprise, ZoneAdmission, zone: "lab")
    :ok
  end

  test "admits a record whose account's tags may enter the zone" do
    assert :ok = admit(%{data_class: :customer_confidential, residency: "CA"})
    assert :ok = admit(%{data_class: :internal, residency: "CA-ON"})
    assert :ok = admit(%{data_class: :public, residency: "unrestricted"})
  end

  test "refuses an untagged account's records" do
    assert {:deny, :untagged_data_class} = admit(%{data_class: nil, residency: "CA"})
    assert {:deny, :untagged_residency} = admit(%{data_class: :internal, residency: nil})
    assert {:deny, :untagged_data_class} = admit(%{data_class: nil, residency: nil})
  end

  test "refuses a class above the zone's ceiling" do
    Application.put_env(:ash_enterprise, ZoneAdmission, zone: "narrow")
    assert {:deny, :above_ceiling} = admit(%{data_class: :customer_confidential, residency: "CA"})
    assert :ok = admit(%{data_class: :internal, residency: "CA"})
  end

  test "refuses data restricted to the US, or to anywhere the zone is not" do
    assert {:deny, :inadmissible_restriction} = admit(%{data_class: :internal, residency: "US"})

    assert {:deny, :inadmissible_restriction} =
             admit(%{data_class: :internal, residency: "US-NY"})

    assert {:deny, :restriction_unsatisfied} = admit(%{data_class: :internal, residency: "CA-QC"})
  end

  test "refuses everything once the declaration has lapsed" do
    Application.put_env(:ash_enterprise, ZoneAdmission, zone: "lapsed")
    assert {:deny, :declaration_lapsed} = admit(%{data_class: :public, residency: "CA"})
  end

  test "refuses everything when the store's zone is unconfigured or undeclared" do
    Application.delete_env(:ash_enterprise, ZoneAdmission)
    assert {:deny, :undeclared_zone} = admit(%{data_class: :public, residency: "CA"})

    Application.put_env(:ash_enterprise, ZoneAdmission, zone: "nowhere")
    assert {:deny, :undeclared_zone} = admit(%{data_class: :public, residency: "CA"})
  end

  test "refuses a record from an account the projection does not hold, or from none" do
    tagged = %{data_class: :internal, residency: "CA"}
    context = %{owner_id: nil, tenant_id: nil, linked_accounts: %{@account_id => tagged}}

    other = %{source_metadata: %{"linked_account_id" => Ecto.UUID.generate()}}
    assert {:deny, :unknown_linked_account} = ZoneAdmission.admit(other, context)

    assert {:deny, :unknown_linked_account} =
             ZoneAdmission.admit(%{source_metadata: %{}}, context)

    garbage = %{source_metadata: %{"linked_account_id" => "not-a-uuid"}}
    assert {:deny, :unknown_linked_account} = ZoneAdmission.admit(garbage, context)
  end

  defp admit(tags) do
    source = %{source_metadata: %{"linked_account_id" => @account_id}, raw_payload: %{}}

    ZoneAdmission.admit(source, %{
      owner_id: nil,
      tenant_id: nil,
      linked_accounts: %{@account_id => tags}
    })
  end

  defp declare(dir, id, ceiling, declared_at, review_by) do
    path = Path.join(dir, "#{id}.json")

    File.write!(
      path,
      Jason.encode!(%{
        "id" => id,
        "jurisdiction" => "CA-ON",
        "classification_ceiling" => ceiling,
        "inadmissible_restrictions" => ["US"],
        "declared_by" => "Test Operator",
        "declared_at" => Date.to_iso8601(declared_at),
        "review_by" => Date.to_iso8601(review_by)
      })
    )

    path
  end
end
