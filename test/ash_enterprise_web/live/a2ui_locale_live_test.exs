defmodule AshEnterpriseWeb.A2uiLocaleLiveTest do
  @moduledoc """
  A surface rendered in French (ADR 0060, section 5): the labels and chrome the
  application and `ash_a2ui` write come out through the `a2ui_metadata` and
  `ash_a2ui` catalogs, while the records' own values, the data-model paths and
  every identifier are exactly what English serves.
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

  defp surface_json(conn, accept_language, path \\ "/app/legacy-users") do
    {:ok, view, _html} =
      conn |> put_req_header("accept-language", accept_language) |> live(path)

    assert_push_event(view, "a2ui:messages", %{messages: messages})
    JSON.encode!(messages)
  end

  setup %{conn: conn} do
    seeded = AshEnterprise.Platform.Seeder.seed_legacy_estate()
    %{conn: sign_in(conn, seeded.user)}
  end

  test "labels and chrome are French, values and identifiers are unchanged", %{conn: conn} do
    english = surface_json(conn, "en")
    french = surface_json(conn, "fr")

    # The application's labels, through the metadata domain.
    assert english =~ "Legacy state"
    assert french =~ "État dans l’ancien système"
    refute french =~ "Legacy state"

    # A label the host never wrote: humanized from a field name.
    assert english =~ "Login"
    assert french =~ "Connexion"

    # The library's chrome, through the `ash_a2ui` domain.
    assert french =~ "Rechercher"

    # Record values and identifiers do not move.
    for unchanged <- ["Alan Whitfield", "Josefa de la Cruz", "legacy_users", "legacy_state"] do
      assert english =~ unchanged
      assert french =~ unchanged
    end
  end

  test "a locale with no catalog is English", %{conn: conn} do
    assert surface_json(conn, "de") == surface_json(conn, "en")
  end

  test "enum labels are French, the enum's values and the record's name are not", %{conn: _conn} do
    ctx = tenant!()

    AshEnterprise.Accounts.Team
    |> Ash.Changeset.for_create(
      :create,
      %{name: "Facilities crew", team_type: :owner},
      actor: ctx.user,
      tenant: ctx.tenant
    )
    |> Ash.create!()

    conn = Phoenix.ConnTest.build_conn() |> sign_in(ctx.user)
    english = surface_json(conn, "en", "/app/teams")
    french = surface_json(conn, "fr", "/app/teams")

    assert english =~ "Owner"
    assert french =~ "Propriétaire"
    refute french =~ "Owner"

    for unchanged <- ["Facilities crew", "owner"] do
      assert english =~ unchanged
      assert french =~ unchanged
    end
  end

  test "the registry's labels in the nav are French", %{conn: conn} do
    {:ok, view, _html} = conn |> put_req_header("accept-language", "fr") |> live("/app")

    assert render(view) =~ "Ma journée"
  end
end
