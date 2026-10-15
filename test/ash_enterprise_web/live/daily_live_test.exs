defmodule AshEnterpriseWeb.DailyLiveTest do
  @moduledoc """
  The daily-loop pages (`AshEnterpriseWeb.DailyLive`) through the real
  LiveViews: each mounts its A2UI surface for the signed-in actor and pushes
  it; Today runs its reports on arrival; the inbox pages say which kind of
  empty they are; Approve on Today decides the brief through its approval
  task; and the erasure page is the platform operator's alone.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AshEnterprise.Test.DailyFixtures

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

  setup %{conn: conn} do
    ctx = tenant!(operator?: true)
    %{conn: sign_in(conn, ctx.user), ctx: ctx}
  end

  @pages ~w(today calendar inbox slack people approvals accounts erasure)

  test "every daily-loop page mounts its surface", %{conn: conn} do
    for page <- @pages do
      {:ok, view, html} = live(conn, "/app/#{page}")

      assert has_element?(view, "#ash-a2ui-surface[phx-hook=AshA2ui]"), page
      assert html =~ ~s(phx-update="ignore")
      assert has_element?(view, "#nav-today"), page
      assert has_element?(view, "#nav-day"), page
      assert has_element?(view, "#nav-group-operator"), page
      assert has_element?(view, "#nav-#{page}[aria-current=page]"), page
      assert has_element?(view, "#page-header h1"), page

      assert pushed(view) =~ "createSurface", page
    end
  end

  test "Today pushes the brief, then its agenda and pulse reports", %{conn: conn, ctx: ctx} do
    event!(ctx, "Synthetic standup", 2, 15)
    brief!(ctx)

    {:ok, view, _html} = live(conn, "/app/today")

    bootstrap = pushed(view)
    assert bootstrap =~ "Waiting for your approval" or bootstrap =~ "pending_approval"
    assert bootstrap =~ "1 event"

    reports = pushed(view)
    assert reports =~ "/report/agenda/rows"
    assert reports =~ "Synthetic standup"
    assert reports =~ "/report/pulse/rows"
    assert reports =~ "1 waiting"
  end

  test "Approve on Today decides the brief through its approval task", %{conn: conn, ctx: ctx} do
    brief = brief!(ctx)

    {:ok, view, _html} = live(conn, "/app/today")
    _bootstrap = pushed(view)
    _reports = pushed(view)

    render_hook(view, "a2ui:action", %{
      "version" => "v1.0",
      "action" => %{
        "name" => "invoke",
        "surfaceId" => "today",
        "sourceComponentId" => "data_grid_brief",
        "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
        "context" => %{"action" => "approve", "recordId" => brief.id, "component" => "brief"}
      }
    })

    assert %{status: :approved} = reload_brief!(brief, ctx.tenant)
  end

  test "an empty inbox explains itself; one with mail does not", %{conn: conn, ctx: ctx} do
    {:ok, view, _html} = live(conn, "/app/inbox")
    _ = pushed(view)
    assert render_async(view) =~ "held back until zone admission (ADR 0042)"
    assert has_element?(view, "#inbox-notice")

    conversation!(ctx, "slack", "#eng", "Deploy is green")
    {:ok, view, _html} = live(conn, "/app/slack")
    assert pushed(view) =~ "Deploy is green"
    render_async(view)
    refute has_element?(view, "#inbox-notice")
  end

  test "the erasure page is the platform operator's alone", %{conn: _conn} do
    admin = tenant!()
    conn = sign_in(build_conn(), admin.user)

    assert {:error, {:redirect, %{to: "/app", flash: flash}}} = live(conn, "/app/erasure")
    assert flash["error"] =~ "platform operator"
  end

  test "signing in lands on the launcher", %{ctx: ctx} do
    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Phoenix.ConnTest.fetch_flash()
      |> AshEnterpriseWeb.AuthController.success({:password, :sign_in}, ctx.user, nil)

    assert redirected_to(conn) == "/app"
  end
end
