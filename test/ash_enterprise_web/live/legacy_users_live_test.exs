defmodule AshEnterpriseWeb.LegacyUsersLiveTest do
  @moduledoc """
  The live half of the strangler demonstration, driven through the actual
  LiveView.

  `AshEnterprise.Legacy.ReadModelTest` proves a legacy write reaches the
  Phoenix.PubSub topic. This proves the other end: that the surface subscribed to
  it, that a broadcast on that topic makes it rebuild, and that the viewer is
  told so.

  Both halves are needed because the joint between them is two independent
  spellings of the same topic strings, and a mismatch produces a page that
  silently never updates.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshEnterprise.Legacy.Estate

  setup %{conn: conn} do
    seeded = AshEnterprise.Platform.Seeder.seed_legacy_estate()

    %{conn: sign_in(conn, seeded.user), seeded: seeded}
  end

  # `require_token_presence_for_authentication? true` on the User resource, so
  # the session carries a JWT under "user_token" and `LiveSession` looks the
  # token's `jti` up in the token resource. A bare subject string under "user"
  # is the *other* configuration, and silently redirects to /sign-in here.
  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  test "the surface renders the legacy rows", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/app/legacy-users")

    # The renderer owns its own DOM and paints from a pushed message, so the
    # rows are not in the server-rendered HTML. What IS assertable here is that
    # the hook container was rendered and told to keep LiveView out of it.
    assert html =~ ~s(id="ash-a2ui-surface")
    assert html =~ ~s(phx-hook="AshA2ui")
    assert html =~ ~s(phx-update="ignore")
  end

  test "mounting pushes a surface built from the legacy read model", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/app/legacy-users")

    assert_push_event(view, "a2ui:messages", %{messages: messages})

    # Seeded legacy people, arriving through the compatibility view, encoded as
    # A2UI protocol messages -- with no code written for any of it.
    encoded = JSON.encode!(messages)
    assert encoded =~ "Alan Whitfield"
    assert encoded =~ "Josefa de la Cruz"

    # Soft-deleted in the legacy schema (`deleted_at`), and therefore filtered
    # here by AshArchival without either application knowing about the other.
    refute encoded =~ "Tomas O"
  end

  test "a broadcast on a published topic rebuilds the surface and raises the cue",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/app/legacy-users")

    assert_push_event(view, "a2ui:messages", %{messages: _})

    # Exactly what `Ash.Notifier.PubSub` emits for this resource when the
    # listener dispatches a legacy write.
    AshEnterpriseWeb.Endpoint.broadcast!("legacy_users:created", "legacy_write", %{})

    # The renderer debounces 150 ms, so the refresh is not synchronous.
    assert_push_event(view, "a2ui:messages", %{messages: [refresh]}, 2_000)
    assert Map.has_key?(refresh, "updateDataModel")

    assert render(view) =~ "The legacy application changed these rows"
  end

  test "the cue counts repeated changes and then clears itself", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/app/legacy-users")
    assert_push_event(view, "a2ui:messages", %{messages: _})

    AshEnterpriseWeb.Endpoint.broadcast!("legacy_users:created", "legacy_write", %{})
    assert_push_event(view, "a2ui:messages", %{messages: [_]}, 2_000)

    AshEnterpriseWeb.Endpoint.broadcast!("legacy_users:updated", "legacy_write", %{})
    assert_push_event(view, "a2ui:messages", %{messages: [_]}, 2_000)

    # The banner is keyed on the count, so the element is removed and re-added
    # on each refresh -- which is what makes `phx-mounted` fire a second time
    # rather than only on the first change.
    html = render(view)
    assert html =~ "2 updates"
    assert html =~ ~s(id="legacy-cue-2")

    # And it takes itself away. A cue that never clears stops being a cue.
    send(view.pid, :clear_cue)
    refute render(view) =~ "The legacy application changed these rows"
  end

  test "a viewer outside the legacy tenant gets a surface with no legacy rows", %{conn: conn} do
    greenfield =
      AshEnterprise.Platform.Seeder.seed_tenant(
        unique_name: "greenfield-live-#{System.unique_integer([:positive])}"
      )

    refute greenfield.organization.id == Estate.organization_id()

    {:ok, view, _html} = conn |> sign_in(greenfield.user) |> live("/app/legacy-users")

    assert_push_event(view, "a2ui:messages", %{messages: messages})

    # The surface still builds -- an actor with no reach gets an empty table
    # rather than a 403 -- and it contains nobody from the legacy estate.
    refute JSON.encode!(messages) =~ "Alan Whitfield"
  end
end
