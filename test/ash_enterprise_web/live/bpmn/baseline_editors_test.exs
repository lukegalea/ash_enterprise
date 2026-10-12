defmodule AshEnterpriseWeb.Bpmn.BaselineEditorsTest do
  @moduledoc """
  Opening an editor on a key the tenant has not customized.

  The regression: in the dogfood instance, opening `/app/processes/morning.brief/designer` for a
  tenant running the platform baseline created a tenant draft from `ash_bpmn`'s starter template
  -- three nodes, no diagram section -- so bpmn-js showed "no diagram to display" and the
  catalogue showed a customization nobody had made. Opening must show the baseline, read-only,
  and store nothing; making it the tenant's own is the Customize button, which is
  `Resolver.fork/4`, exactly as on the catalogue.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  require Ash.Query

  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Process.Resolver

  @brief_xml File.read!("priv/bpmn/morning_brief.bpmn")
  @risk_xml File.read!("priv/dmn/access_request_risk.dmn")

  setup %{conn: conn} do
    platform = Seeder.seed_platform_organization()
    on_exit(&Resolver.forget_platform_tenant/0)

    publish!(AshEnterprise.Bpmn.Definition, "morning.brief", @brief_xml, platform.id)
    publish!(AshEnterprise.Decisions.Definition, "access_request.risk", @risk_xml, platform.id)

    seeded =
      Seeder.seed_tenant(
        unique_name: "baseline-#{System.unique_integer([:positive])}",
        email: "baseline-#{System.unique_integer([:positive])}@example.com"
      )

    %{conn: sign_in(conn, seeded.user), tenant: seeded.organization.id}
  end

  defp publish!(resource, key, xml, tenant) do
    opts = [actor: SystemActor.process(), tenant: tenant]
    definition = resource.create!(%{key: key, name: key, xml: xml}, opts)
    resource.publish!(definition, opts)
  end

  # `require_token_presence_for_authentication? true` on the User resource: the session
  # carries a JWT under "user_token". See `LegacyUsersLiveTest` for the longer note.
  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp tenant_rows(resource, key, tenant) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(key == ^key)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
  end

  describe "the process designer" do
    test "an un-customized baseline key renders the baseline and creates no row", ctx do
      {:ok, view, _html} = live(ctx.conn, "/app/processes/morning.brief/designer")

      # The baseline's own nodes and its diagram, not the starter's Task_1.
      assert has_element?(view, "#ash-bpmn-designer[data-xml*='ComposeDraft']")
      assert has_element?(view, "#ash-bpmn-designer[data-xml*='bpmndi:BPMNDiagram']")
      refute has_element?(view, "#ash-bpmn-designer[data-xml*='Task_1']")

      assert has_element?(view, "#bpmn-origin", "baseline v1")
      assert has_element?(view, "#bpmn-customize-btn")
      refute has_element?(view, "#bpmn-save-btn")

      assert tenant_rows(AshEnterprise.Bpmn.Definition, "morning.brief", ctx.tenant) == []
    end

    test "Customize forks the baseline into the tenant's own draft", ctx do
      {:ok, view, _html} = live(ctx.conn, "/app/processes/morning.brief/designer")

      view |> element("#bpmn-customize-btn") |> render_click()

      assert [draft] = tenant_rows(AshEnterprise.Bpmn.Definition, "morning.brief", ctx.tenant)
      assert draft.status == :draft
      assert draft.xml == String.trim(@brief_xml)

      assert has_element?(view, "#bpmn-save-btn")
      assert_push_event(view, "load_xml", %{xml: xml})
      assert xml =~ "ComposeDraft"
    end

    test "a brand-new key opens on a starter that has a diagram, and stores nothing", ctx do
      {:ok, view, _html} = live(ctx.conn, "/app/processes/brand.new/designer")

      assert has_element?(view, "#ash-bpmn-designer[data-xml*='bpmndi:BPMNDiagram']")
      assert has_element?(view, "#bpmn-save-btn")
      assert tenant_rows(AshEnterprise.Bpmn.Definition, "brand.new", ctx.tenant) == []
    end
  end

  describe "the decision editor" do
    test "an un-customized baseline key renders the baseline and creates no row", ctx do
      {:ok, view, _html} = live(ctx.conn, "/app/decisions/access_request.risk/editor")

      assert has_element?(view, "#decision-origin", "baseline v1")
      assert has_element?(view, "#decision-customize")
      refute has_element?(view, "#decision-save")

      assert tenant_rows(AshEnterprise.Decisions.Definition, "access_request.risk", ctx.tenant) ==
               []
    end

    test "Customize forks the baseline into the tenant's own draft", ctx do
      {:ok, view, _html} = live(ctx.conn, "/app/decisions/access_request.risk/editor")

      view |> element("#decision-customize") |> render_click()

      assert [%{status: :draft}] =
               tenant_rows(AshEnterprise.Decisions.Definition, "access_request.risk", ctx.tenant)

      assert has_element?(view, "#decision-save")
    end
  end
end
