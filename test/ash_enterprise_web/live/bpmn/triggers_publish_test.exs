defmodule AshEnterpriseWeb.Bpmn.TriggersPublishTest do
  @moduledoc """
  The lifecycle controls on `/app/triggers`: a draft recipe has Publish (the authority the
  draft carries) and Publish with my authority (`publish_granted`, a standing grant), a
  published one has Disable or Enable, and Retire. Each runs as the signed-in person, so a
  person without the grant is refused and the recipe is left as it was, and a recipe of
  another tenant is not found.
  SYNTHETIC data only.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  require Ash.Query

  alias AshEnterprise.Bpmn.Subscription
  alias AshEnterprise.Test.{AssistantFixtures, DailyFixtures}

  @recipe "soc2.cc6_3.role_assigned"

  setup do
    admin = AssistantFixtures.tenant!()
    {:ok, _} = Subscription.install_pack("soc2_cc6_3", actor: admin.actor, tenant: admin.tenant)
    [draft] = recipes(admin.tenant)
    %{admin: admin, draft: draft}
  end

  # `require_token_presence_for_authentication? true` on the User resource: the session
  # carries a JWT under "user_token".
  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp recipes(tenant) do
    Subscription
    |> Ash.Query.filter(key == @recipe)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  defp reload(recipe, tenant),
    do: Ash.get!(Subscription, recipe.id, authorize?: false, tenant: tenant)

  defp triggers(conn, user) do
    {:ok, view, _html} = conn |> sign_in(user) |> live(~p"/app/triggers")
    view
  end

  test "a person without the grant cannot publish a draft, either way", %{
    conn: conn,
    admin: admin,
    draft: draft
  } do
    nobody = DailyFixtures.member!(admin, "Nobody #{System.unique_integer([:positive])}", [])

    reader =
      DailyFixtures.member!(admin, "Recipe reader #{System.unique_integer([:positive])}", [
        {Subscription, :read, :global}
      ])

    for person <- [nobody, reader],
        button <- ["#publish-#{draft.id}", "#publish-granted-#{draft.id}"] do
      view = triggers(conn, person.user)
      assert has_element?(view, button)

      view |> element(button) |> render_click()
      assert render(view) =~ "may not change this recipe" or render(view) =~ "was not changed"

      assert %{status: :draft, accountable_person_id: nil} = reload(draft, admin.tenant)
    end
  end

  test "a recipe of another tenant is not found, and is left as it was", %{
    conn: conn,
    draft: draft
  } do
    other = AssistantFixtures.tenant!()
    view = triggers(conn, other.user)

    refute has_element?(view, "#publish-#{draft.id}")

    # The event, sent as a forged client would send it.
    render_click(view, "publish", %{"id" => draft.id})
    assert render(view) =~ "was not changed"

    assert %{status: :draft} = reload(draft, draft.organization_id)
  end

  test "an administrator publishes a draft, then disables, enables and retires it", %{
    conn: conn,
    admin: admin,
    draft: draft
  } do
    view = triggers(conn, admin.user)

    view |> element("#publish-#{draft.id}") |> render_click()

    assert %{status: :published, enabled: true, authority: :human_tasks_only} =
             reload(draft, admin.tenant)

    assert render(view) =~ "Published #{@recipe} v#{draft.version}."

    view |> element("#disable-#{draft.id}") |> render_click()
    assert %{enabled: false} = reload(draft, admin.tenant)

    view |> element("#enable-#{draft.id}") |> render_click()
    assert %{enabled: true} = reload(draft, admin.tenant)

    view |> element("#retire-#{draft.id}") |> render_click()
    assert %{status: :retired} = reload(draft, admin.tenant)
    refute has_element?(view, "#retire-#{draft.id}")
  end

  test "publishing with my authority is the person's standing grant", %{
    conn: conn,
    admin: admin,
    draft: draft
  } do
    # A standing grant covers the published diagrams its publisher sees, so the pack's
    # process is published first, as the pack's description says.
    AshEnterprise.Bpmn.Definition
    |> Ash.Query.filter(key == ^draft.process_key)
    |> Ash.read_one!(authorize?: false, tenant: admin.tenant)
    |> AshEnterprise.Bpmn.Definition.publish!(
      actor: AshEnterprise.Platform.SystemActor.process(),
      tenant: admin.tenant
    )

    view = triggers(conn, admin.user)
    view |> element("#publish-granted-#{draft.id}") |> render_click()

    assert %{status: :published, authority: :standing_grant, accountable_person_id: person} =
             reload(draft, admin.tenant)

    assert person == admin.user.id
  end
end
