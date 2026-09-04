defmodule AshEnterpriseWeb.Bpmn.DesignerLiveTest do
  @moduledoc """
  The host designer, fed by the host catalogue.

  The properties panel must render *choices* — a decision select drawn from the keys this
  actor can actually open in their editor, an action select drawn from the invoker's
  registry — and the "Edit decision" deep link into the DMN editor. These are the three
  catalogue MFAs arriving through the real LiveView, not through a double.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshEnterprise.Decisions
  alias AshEnterprise.Platform.{Seeder, SystemActor}

  setup %{conn: conn} do
    Seeder.seed_platform_organization()

    seeded =
      Seeder.seed_tenant(
        unique_name: "designer-#{System.unique_integer([:positive])}",
        email: "designer-#{System.unique_integer([:positive])}@example.com"
      )

    publish_risk_decision!(seeded.organization.id)

    %{conn: sign_in(conn, seeded.user), tenant: seeded.organization.id}
  end

  defp publish_risk_decision!(tenant) do
    opts = [actor: SystemActor.process(), tenant: tenant]
    xml = File.read!("priv/dmn/access_request_risk.dmn")

    definition =
      Decisions.Definition.create!(
        %{key: "access_request.risk", name: "Access request risk", xml: xml},
        opts
      )

    Decisions.Definition.publish!(definition, opts)
  end

  # `require_token_presence_for_authentication? true` on the User resource: the session
  # carries a JWT under "user_token". See `LegacyUsersLiveTest` for the longer note.
  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp open_designer(conn) do
    {:ok, view, _html} = live(conn, "/app/processes/access_request.grant/designer")
    view
  end

  test "the business rule panel renders the decision catalogue", %{conn: conn} do
    view = open_designer(conn)

    html =
      render_hook(view, "selection_changed", %{
        "id" => "AssessRisk",
        "type" => "bpmn:BusinessRuleTask",
        "name" => "Assess risk",
        "config" => %{
          "decision" => %{"ref" => "access_request.risk", "binding" => "latest"},
          "inputs" => [%{"name" => "requestedRoleTier", "from" => "subject.requested_role_tier"}],
          "promote" => [%{"name" => "risk_tier", "from" => "RiskTier", "required" => "true"}]
        }
      })

    # A select drawn from the catalogue, not free text, with the entry chosen
    assert html =~ ~s(<select id="config-decision-ref" name="decision_ref")
    assert html =~ ~s(value="access_request.risk" selected)
    assert html =~ "Access request risk"

    # The publish status a modeller needs next to the choice
    assert html =~ "published v1"

    # The deep link into the DMN editor: where it goes, and that it opens beside, not over
    assert html =~ ~s(href="/app/decisions/access_request.risk/editor")
    assert html =~ ~s(target="_blank")
    assert html =~ "Edit decision"
  end

  test "the service task panel renders the action catalogue", %{conn: conn} do
    view = open_designer(conn)

    html =
      render_hook(view, "selection_changed", %{
        "id" => "RecordRisk",
        "type" => "bpmn:ServiceTask",
        "name" => "Record the risk",
        "config" => %{
          "action" => "record_risk",
          "inputs" => [%{"name" => "risk_tier", "from" => "routing.risk_tier"}],
          "promote" => []
        }
      })

    assert html =~ ~s(<select id="config-action" name="action")
    assert html =~ ~s(value="record_risk" selected)

    # Every registry ref is on offer, and the Ash-backed one is described by its own action
    assert html =~ ~s(value="grant_role")
    assert html =~ ~s(value="reject_request")
    assert html =~ "Records what the risk decision returned"

    # `record_risk` accepts `:risk_tier` as an attribute, not an action argument, so the
    # catalogue truthfully declares no arguments for it and the panel renders no typed arg
    # rows: the tier the diagram passes is a declared `ash:input`, a plain FEEL row.
    refute html =~ ~s(name="inputs_from[]")
  end
end
