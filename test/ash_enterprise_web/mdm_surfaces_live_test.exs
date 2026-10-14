defmodule AshEnterpriseWeb.MdmSurfacesLiveTest do
  @moduledoc """
  The MDM A2UI surfaces driven through the actual LiveView: a signed-in
  steward sees real rows in the pushed `a2ui:messages` — mappings on one
  surface, golden records (never merged losers) on the other.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AshEnterprise.Mdm.TestSupport

  alias AshEnterprise.Mdm.SourceIdentity
  alias AshEnterprise.Platform.Seeder

  require Ash.Query

  setup %{conn: conn} do
    %{organization: organization, user: admin} =
      Seeder.seed_tenant(
        name: "Mdm Surface #{System.unique_integer([:positive])}",
        unique_name: "mdm-surface-#{System.unique_integer([:positive])}"
      )

    %{conn: sign_in(conn, admin), org: organization.id, admin: admin}
  end

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  # The surface may split its payload across pushes (surface, then rows).
  # Collect every a2ui:messages push and assert against the joined payload.

  defp pushed_json(view) do
    assert_push_event(view, "a2ui:messages", %{messages: first}, 2000)
    push_all(view, [JSON.encode!(first)])
  end

  defp push_all(view, acc) do
    assert_push_event(view, "a2ui:messages", %{messages: messages}, 100)
    push_all(view, acc ++ [JSON.encode!(messages)])
  rescue
    ExUnit.AssertionError -> Enum.join(acc, "\n")
  end

  test "the mapping surface shows the tenant's mapping version", %{
    conn: conn,
    org: org,
    admin: admin
  } do
    activate_host_mapping!(draft_host_mapping!(org, []), org, admin)

    {:ok, view, _html} = live(conn, "/app/mdm/mappings")

    # The surface mounts and announces itself; the rows come through the
    # resource's own read, which is what the unit-level assertion pins.
    encoded = pushed_json(view)
    assert encoded =~ "mdm_mappings"
    # The steward's rows are IN the surface: the live mapping version shows.
    assert encoded =~ "AshEnterprise.Canonical.Person"
  end

  test "the golden surface shows goldens and never merged losers", %{
    conn: conn,
    org: org,
    admin: admin
  } do
    golden =
      AshEnterprise.Canonical.Person
      |> Ash.Changeset.for_create(:upsert_from_source, %{
        name: "Golda Golden",
        email: "golda@x.io",
        owner_id: admin.id,
        owning_business_unit_id: admin.owning_business_unit_id
      })
      |> Ash.create!(tenant: org, authorize?: false)

    # A golden is golden because an identity points at it.
    SourceIdentity
    |> Ash.Changeset.for_create(
      :open,
      %{
        source: "manual_csv",
        stream: "upload",
        external_id: "#{org}:acme:golda",
        golden_resource: "AshEnterprise.Canonical.Person",
        golden_id: golden.id,
        asserted_by: :steward
      },
      tenant: org,
      authorize?: false
    )
    |> Ash.create!(tenant: org, authorize?: false)

    loser =
      AshEnterprise.Canonical.Person
      |> Ash.Changeset.for_create(:upsert_from_source, %{
        name: "Loser McAbsorbed",
        email: "loser@x.io",
        owner_id: admin.id,
        owning_business_unit_id: admin.owning_business_unit_id
      })
      |> Ash.create!(tenant: org, authorize?: false)

    # The loser is absorbed: merged, pointing at its survivor.
    loser
    |> Ash.Changeset.for_update(:mdm_merge_into, %{survivor_id: golden.id},
      tenant: org,
      authorize?: false
    )
    |> Ash.update!(tenant: org, authorize?: false)

    {:ok, view, _html} = live(conn, "/app/mdm/golden")

    encoded = pushed_json(view)
    assert encoded =~ "mdm_golden"

    # The surface itself shows the survivor and never the absorbed loser —
    # the merged loser must not present itself as the customer.
    assert encoded =~ "Golda Golden"
    refute encoded =~ "Loser McAbsorbed"
  end
end
