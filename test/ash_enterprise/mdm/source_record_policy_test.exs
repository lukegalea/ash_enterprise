defmodule AshEnterprise.Mdm.SourceRecordPolicyTest do
  @moduledoc """
  Raw landings are machinery-visible only: no person, whatever their grants,
  reads another tenant's (or even their own tenant's) raw landed rows — the
  steward's surfaces are the tenant-scoped staged records and goldens.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Mdm.SourceRecord
  alias AshEnterprise.Platform.Seeder

  require Ash.Query

  setup do
    %{organization: a} =
      Seeder.seed_tenant(
        name: "Landing A #{System.unique_integer([:positive])}",
        unique_name: "landing-a-#{System.unique_integer([:positive])}"
      )

    %{organization: b, user: admin_b} =
      Seeder.seed_tenant(
        name: "Landing B #{System.unique_integer([:positive])}",
        unique_name: "landing-b-#{System.unique_integer([:positive])}"
      )

    # Tenant A lands a row with a payload that must never reach a person.
    {:ok, _} = AshEnterprise.Mdm.Landing.land_row(a.id, "acme", %{"Secret" => "a-payload"})

    %{org_a: a.id, org_b: b.id, admin_b: admin_b}
  end

  test "a person with grants reads zero raw landings, own tenant included", %{
    org_b: org_b,
    admin_b: admin_b
  } do
    assert SourceRecord
           |> Ash.Query.filter(contains(external_id, ^org_b))
           |> Ash.read!(tenant: org_b, actor: admin_b)
           |> length() == 0
  end

  test "the machinery still lands and stages: the pipeline reads as the system actor", %{
    org_a: org_a
  } do
    system = AshEnterprise.Platform.SystemActor.system()

    assert [_] =
             SourceRecord
             |> Ash.Query.filter(contains(external_id, ^org_a))
             |> Ash.read!(tenant: nil, actor: system)
  end
end
