defmodule AshEnterpriseWeb.GuideLiveTest do
  @moduledoc """
  The guide pages (`AshEnterpriseWeb.GuideLive`) and their figures
  (`AshEnterpriseWeb.GuideFigureController`), as a member with no grants: the
  shell's `/guide <journey>` opens one, the page carries the approved run's steps
  in the reader's locale, and only the figures the lock approves are served, to
  people signed in. The browser tier shows them rendered
  (`test/e2e/guide_test.exs`).

  SYNTHETIC data only.
  """

  use AshEnterpriseWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import AshEnterprise.Test.DailyFixtures

  alias AshEnterprise.Surfaces

  @path "/app/guide/revoke_a_leavers_access"

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  setup %{conn: conn} do
    admin = tenant!()
    member = member!(admin, "Reader", [])
    %{conn: sign_in(conn, member.user), member: member}
  end

  defp messages(view) do
    assert_push_event(view, "a2ui:messages", %{messages: messages}, 5_000)
    JSON.encode!(messages)
  end

  test "the shell's /guide <journey> opens the guide", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/app")
    render_hook(element(view, "#a2ui-shell"), "shell:open", %{"mode" => "palette"})

    assert {:error, {:live_redirect, %{to: @path}}} =
             view
             |> element("#a2ui-shell-form")
             |> render_submit(%{"query" => "/guide revoke_a_leavers_access"})
  end

  test "is in the launcher and the palette for a member with no grants", %{member: member} do
    assert Enum.any?(
             AshEnterpriseWeb.Shell.surfaces(member.actor),
             &(&1["id"] == "guide_revoke_a_leavers_access")
           )

    assert Enum.any?(
             AshEnterpriseWeb.Shell.commands(member.actor),
             &(&1["name"] == "guide revoke_a_leavers_access")
           )
  end

  test "shows the approved run's steps under the journey's title", %{conn: conn} do
    {:ok, view, html} = live(conn, @path)

    assert html =~ "Revoke a leaver&#39;s access"
    assert view.module == Surfaces.fetch!(:guide_revoke_a_leavers_access).live

    sent = messages(view)
    assert sent =~ "2. Open **Users** and find the person who is leaving."
    assert sent =~ "/app/guide/figures/"
  end

  test "reads in the reader's locale", %{conn: conn} do
    {:ok, view, html} = conn |> put_req_header("accept-language", "fr") |> live(@path)

    assert html =~ "Révoquer l&#39;accès"
    assert messages(view) =~ "Ouvrez **Utilisateurs**"
  end

  describe "a figure" do
    test "the lock approves is a PNG, cached for good", %{conn: conn} do
      [digest | _] = approved_digests()
      conn = get(conn, "/app/guide/figures/#{digest}.png")

      assert <<137, "PNG", _rest::binary>> = response(conn, 200)
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert ["private, max-age=31536000, immutable"] = get_resp_header(conn, "cache-control")
    end

    test "the lock does not approve is not found", %{conn: conn} do
      assert conn |> get("/app/guide/figures/#{String.duplicate("a", 64)}.png") |> response(404)
      assert conn |> get("/app/guide/figures/journeys.lock.json") |> response(404)
    end

    test "is for people signed in" do
      [digest | _] = approved_digests()
      conn = get(build_conn(), "/app/guide/figures/#{digest}.png")
      assert redirected_to(conn) == "/sign-in"
    end
  end

  defp approved_digests do
    {:ok, lock} = AshJourneys.Lock.read(File.cwd!())

    for {_id, locales} <- lock.journeys,
        {_locale, entry} <- locales,
        {_key, figure} <- entry.figures,
        do: figure.file_sha256
  end
end
