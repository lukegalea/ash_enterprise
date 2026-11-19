defmodule AshEnterpriseWeb.A2ui.SurfaceExportTest do
  @moduledoc """
  The CSV export the table surfaces declare (ash_a2ui's `export` block), driven
  through ash_a2ui's own handler as the person who clicks it, and through the real
  LiveView for the door. The export re-reads the table as that person, so it
  carries exactly the rows their grants reach; a surface whose door is closed to
  them never mounts, and a direct export as them still reads nothing. SYNTHETIC
  data only.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshEnterprise.Accounts.{BusinessUnit, Team}
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Test.DailyFixtures
  alias AshEnterpriseWeb.A2ui.{AuditUI, BusinessUnitUI, TeamUI, UserUI}

  defp export(person, ui, context \\ %{}) do
    AshA2ui.ActionHandler.handle(
      ui,
      AshEnterprise.A2uiMessage.ash_action(ui, "export", context),
      actor: person.actor,
      tenant: person.tenant
    )
  end

  # The CSV the handler hands the browser: the `downloadFile` call's data URL.
  defp csv!({:ok, messages}) do
    "data:text/csv;base64," <> encoded =
      Enum.find_value(messages, fn
        %{"callRendererFunction" => %{"callFunction" => %{"@call" => "downloadFile"} = call}} ->
          call["args"]["dataUrl"]

        _other ->
          nil
      end) || flunk("no downloadFile in #{inspect(messages)}")

    [header | rows] = encoded |> Base.decode64!() |> String.split("\r\n", trim: true)
    {header, rows}
  end

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp teams_in!(admin, unit_id, names) do
    %Ash.BulkResult{status: :success} =
      names
      |> Enum.map(&%{name: &1, owning_business_unit_id: unit_id})
      |> Ash.bulk_create!(Team, :create,
        tenant: admin.tenant,
        actor: SystemActor.seed(),
        authorize?: false,
        return_errors?: true,
        stop_on_error?: true
      )
  end

  test "a surface export carries only the rows the reader's grants reach" do
    admin = DailyFixtures.tenant!()
    other = DailyFixtures.tenant!()
    root = admin.user.owning_business_unit_id

    branch =
      BusinessUnit
      |> Ash.Changeset.for_create(:create, %{name: "Branch", parent_business_unit_id: root},
        authorize?: false,
        tenant: admin.tenant,
        actor: SystemActor.seed()
      )
      |> Ash.create!()

    teams_in!(admin, root, ["Root team A", "Root team B"])
    teams_in!(admin, branch.id, ["Branch team A", "Branch team B"])
    DailyFixtures.teams!(other, 2, prefix: "Elsewhere")

    # A local team read in the root unit: the root's teams only.
    local = DailyFixtures.member!(admin, "Local team reader", [{Team, :read, :local}])
    {header, rows} = local |> export(TeamUI) |> csv!()
    exported = Enum.join(rows, "\n")

    assert header =~ "Name"
    assert exported =~ "Root team A" and exported =~ "Root team B"
    refute exported =~ "Branch team"
    refute exported =~ "Elsewhere"

    # Nobody else's grants: the administrator reaches both units, still not the other tenant.
    {_header, rows} = admin |> export(TeamUI) |> csv!()
    exported = Enum.join(rows, "\n")
    assert exported =~ "Root team A" and exported =~ "Branch team A"
    refute exported =~ "Elsewhere"

    # A person with no team grant exports a header and no rows.
    nobody = DailyFixtures.member!(admin, "Nothing", [])
    assert {_header, []} = nobody |> export(TeamUI) |> csv!()
  end

  test "a reader whose surface door is closed gets no export" do
    admin = DailyFixtures.tenant!()
    nobody = DailyFixtures.member!(admin, "Nothing", [])

    # The audit trail's door is the audit grant: the page never mounts for them, so
    # its Export button is never on their screen.
    conn = sign_in(build_conn(), nobody.user)
    assert {:error, {:redirect, %{to: "/app", flash: flash}}} = live(conn, ~p"/app/audit")
    assert flash["error"] =~ "audit grant"

    # And the export itself, sent straight to the handler as them, reads as them:
    # a header, no entries.
    assert {_header, []} = nobody |> export(AuditUI) |> csv!()

    # The administrator, whose door is open, exports the trail their seeding wrote.
    {header, rows} = admin |> export(AuditUI) |> csv!()
    assert header =~ "Resource"
    assert rows != []
  end

  test "an exporting table is still drawn as the admin data grid, with its Export button" do
    admin = DailyFixtures.tenant!()

    for ui <- [TeamUI, UserUI, BusinessUnitUI, AuditUI] do
      json =
        ui
        |> AshA2ui.Info.build_surface(
          actor: admin.actor,
          tenant: admin.tenant,
          catalog: :admin_v1
        )
        |> JSON.encode!()

      assert json =~ ~s("component":"dataGrid"), "#{inspect(ui)} fell back to the basic list"
      assert json =~ "Export CSV", "#{inspect(ui)} has no Export button"
    end
  end

  test "the export offers only its declared columns, and honours the reader's choice" do
    admin = DailyFixtures.tenant!()

    {header, _rows} =
      admin
      |> export(UserUI, %{"columns" => %{"email" => true, "created_on" => false}})
      |> csv!()

    assert header == "Email"

    # A column the surface did not declare is ignored, never exported.
    {header, _rows} =
      admin
      |> export(BusinessUnitUI, %{
        "columns" => %{"name" => true, "path" => true, "organization_id" => true}
      })
      |> csv!()

    assert header == "Name"
  end
end
