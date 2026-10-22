defmodule AshEnterpriseWeb.LineageLiveTest do
  @moduledoc """
  The Lineage app and the Audit trail through the real LiveViews: both are
  in the launcher for an Administrator; Lineage pushes its live diagram and
  refreshes it when the store records a run (a failure arrives red, without
  a reload); changing the window redraws; and both pages are closed to a
  person without the grant.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]
  import AshEnterprise.Test.LineageFixtures

  alias AshEnterprise.Lineage.Recorder

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp pushed(view) do
    assert_push_event(view, "a2ui:messages", %{messages: messages}, 5_000)
    JSON.encode!(messages)
  end

  defp sync(tenant, type) do
    correlation = Ash.UUID.generate()

    Recorder.write([
      {event(type, "ingestion", "gmail.sync",
         run_id: correlation,
         inputs: ["gmail.source"],
         outputs: [%{"namespace" => "ingestion", "name" => "ingestion_source_objects"}],
         error: "unauthorized"
       ), %{tenant: tenant}}
    ])

    correlation
  end

  setup %{conn: conn} do
    inline_store!()
    admin = quietly(&tenant!/0)
    %{conn: sign_in(conn, admin.user), admin: admin}
  end

  test "Lineage and the Audit trail are in the launcher", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/app")
    assert has_element?(view, "#launch-group-operator #launch-lineage")
    assert has_element?(view, "#launch-group-operator #launch-audit")
  end

  test "Lineage pushes its diagram, and a failed run arrives red without a reload", %{
    conn: conn,
    admin: admin
  } do
    sync(admin.tenant, :complete)

    {:ok, view, _html} = live(conn, ~p"/app/lineage")
    assert has_element?(view, "#ash-a2ui-surface[phx-hook=AshA2ui]")

    bootstrap = pushed(view)
    assert bootstrap =~ "createSurface"
    assert bootstrap =~ "liveDiagram"
    assert bootstrap =~ "ingestion.gmail.sync"
    refute bootstrap =~ ~s("status":"failed")

    _ = render_async(view)
    sync(admin.tenant, :fail)

    refresh = pushed(view)
    assert refresh =~ "/diagram/graph" or refresh =~ ~s("diagram")
    assert refresh =~ ~s("status":"failed")
    assert refresh =~ ~s("tone":"danger")
  end

  test "changing the window redraws the graph", %{conn: conn, admin: admin} do
    sync(admin.tenant, :complete)
    {:ok, view, _html} = live(conn, ~p"/app/lineage")
    _ = pushed(view)
    _ = render_async(view)

    assert {:error, {:live_redirect, %{to: to}}} =
             render_patch(view, "/app/lineage?ctx[window]=week")

    assert to =~ "ctx[window]=week" or to =~ "ctx%5Bwindow%5D=week"
  end

  test "the Audit trail mounts its surface", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/app/audit")
    assert pushed(view) =~ "Audit trail"
  end

  test "both are closed to a person without the grant", %{admin: admin} do
    nobody = quietly(fn -> member!(admin, "Nothing", []) end)
    conn = sign_in(build_conn(), nobody.user)

    assert {:error, {:redirect, %{to: "/app", flash: flash}}} = live(conn, ~p"/app/lineage")
    assert flash["error"] =~ "lineage grant"

    assert {:error, {:redirect, %{to: "/app", flash: flash}}} = live(conn, ~p"/app/audit")
    assert flash["error"] =~ "audit grant"
  end
end
