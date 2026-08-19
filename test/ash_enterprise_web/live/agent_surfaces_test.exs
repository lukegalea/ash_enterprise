defmodule AshEnterpriseWeb.AgentSurfacesTest do
  @moduledoc """
  The helper agent console showing tables: the declared ones, the ones it
  composes, and what happens to either when the underlying rows change.

  No API key is needed to run any of this, and that is deliberate rather than
  convenient. The model call is the one part of the flow that cannot run without
  a provider; everything after it — resolving a surface name, validating a
  composed spec against the schema, applying the viewer's policies, staying live
  — is ordinary code, and it is the part where a mistake costs something. Tests
  enter through `AshEnterprise.AI.Interpreter.plan/4` with a hand-built intent,
  or through the console's direct-open buttons.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshEnterprise.AI.Intent
  alias AshEnterprise.AI.Interpreter
  alias AshEnterprise.Legacy.Estate
  alias AshEnterprise.Security.ActorContext
  alias AshEnterpriseWeb.A2ui.Host
  alias AshEnterpriseWeb.A2ui.Surfaces

  setup %{conn: conn} do
    seeded = AshEnterprise.Platform.Seeder.seed_legacy_estate()
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(seeded.user)

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session("user_token", token)

    %{conn: conn, seeded: seeded}
  end

  describe "the surface registry" do
    test "every declared surface resolves to a UI module over a real resource" do
      for surface <- Surfaces.all() do
        assert AshA2ui.Info.resource!(surface.ui)
        assert surface.name == Surfaces.fetch(surface.name).name
      end
    end

    test "a name is matched however a person spells it" do
      assert Surfaces.fetch("legacy_users").name == "legacy_users"
      assert Surfaces.fetch("Legacy Users").name == "legacy_users"
      assert Surfaces.fetch("legacy-users").name == "legacy_users"
      assert Surfaces.fetch("  LEGACY USERS  ").name == "legacy_users"
      assert Surfaces.fetch("nonsense") == nil
      assert Surfaces.fetch(nil) == nil
    end

    test "topics come off the resource's publications, not a second list" do
      # The whole reason this function exists. A hand-written topic list is a
      # second spelling of the `pub_sub` block, and the two failing to agree
      # produces a page that silently never updates.
      assert Surfaces.topics(Surfaces.fetch("legacy_users")) == [
               "legacy_users:created",
               "legacy_users:updated",
               "legacy_users:destroyed"
             ]
    end

    test "a surface whose resource publishes nothing is honestly not live" do
      refute Surfaces.live?(Surfaces.fetch("users"))
      assert Surfaces.topics(Surfaces.fetch("users")) == []
    end

    test "the prompt catalogue is generated from the same list the app renders" do
      catalogue = Surfaces.catalogue()

      for surface <- Surfaces.all() do
        assert catalogue =~ surface.name
      end
    end

    test "the dynamic allowlist disambiguates the two User resources" do
      allowlist = Surfaces.dynamic_allowlist()

      # `AshEnterprise.Accounts.User` and `AshEnterprise.Legacy.User` collide on
      # their short name, and that collision is the point of the strangler
      # exercise rather than an accident, so it is not going away.
      assert allowlist["user"] == AshEnterprise.Accounts.User
      assert allowlist["legacy_user"] == AshEnterprise.Legacy.User
    end
  end

  describe "planning, below the model call" do
    test "a show_surface intent resolves to a declared surface" do
      intent = %Intent{kind: :show_surface, surface: "legacy_users"}

      assert {:ok, {:surface, surface}} = Interpreter.plan(intent, "...", nil, nil)
      assert surface.ui == AshEnterpriseWeb.A2ui.LegacyUserUI
    end

    test "a surface name the model invented is refused, and the real names are listed" do
      intent = %Intent{kind: :show_surface, surface: "customers"}

      assert {:error, message} = Interpreter.plan(intent, "...", nil, nil)
      assert message =~ "customers"
      assert message =~ "legacy_users"
    end

    test "an unsupported kind says what the console can do instead" do
      assert {:error, message} = Interpreter.plan(%Intent{kind: :unknown}, "...", nil, nil)

      assert message =~ "legacy_users"
      assert message =~ "assign a role"
    end
  end

  describe "hosting a surface" do
    test "a declared presentation carries its topics and a dynamic one carries the title" do
      declared = Host.declared(Surfaces.fetch("legacy_users"))

      assert declared.kind == :declared
      assert declared.topics != []

      dynamic =
        Host.dynamic(
          %AshA2ui.Dynamic.Surface{
            surface_id: "dyn_x",
            resource: AshEnterprise.Legacy.User,
            title: "t",
            spec: %{},
            dsl_state: %{}
          },
          "Composed table"
        )

      assert dynamic.kind == :dynamic
      assert dynamic.title == "Composed table"

      # A composed table over a resource that publishes is live for exactly the
      # same reason a declared one is. Nothing about being made at runtime makes
      # a surface less able to update itself.
      assert dynamic.topics == declared.topics
    end
  end

  describe "a composed surface" do
    # Resolved from a hand-written spec, which is exactly what the model's output
    # goes through -- so this exercises the whole path below the model call.
    defp composed! do
      {:ok, surface} =
        AshA2ui.Dynamic.resolve(
          %{
            "resource" => "legacy_user",
            "title" => "Logins",
            "queries" => [
              %{
                "name" => "q",
                "sortable" => ["login"],
                "default_sort" => [%{"field" => "login", "direction" => "asc"}]
              }
            ],
            "components" => [%{"kind" => "table", "fields" => ["login", "email"], "query" => "q"}]
          },
          allowlist: Surfaces.dynamic_allowlist()
        )

      surface
    end

    test "a spec naming a field that does not exist is refused, not rendered blank" do
      assert {:error, errors} =
               AshA2ui.Dynamic.resolve(
                 %{
                   "resource" => "legacy_user",
                   "components" => [%{"kind" => "table", "fields" => ["login", "salary"]}]
                 },
                 allowlist: Surfaces.dynamic_allowlist()
               )

      messages = Enum.join(AshA2ui.Dynamic.Error.messages(errors), " ")
      assert messages =~ "salary"
    end

    test "a resource outside the allowlist is refused" do
      # The allowlist is host configuration, not client input. Without this a
      # composed surface is a path to any table in the application.
      assert {:error, _} =
               AshA2ui.Dynamic.resolve(
                 %{
                   "resource" => "audit_event",
                   "components" => [%{"kind" => "table", "fields" => ["id"]}]
                 },
                 allowlist: Surfaces.dynamic_allowlist()
               )
    end

    test "it builds rows under the viewer's actor", ctx do
      admin =
        ActorContext.attach(
          ctx.seeded.user,
          ActorContext.build(ctx.seeded.user, tenant: Estate.organization_id())
        )

      messages =
        AshA2ui.Dynamic.build_surface(composed!(),
          actor: admin,
          tenant: Estate.organization_id()
        )

      assert JSON.encode!(messages) =~ "awhitfield"
    end

    test "it refreshes, which is what the live badge on it promises", ctx do
      admin =
        ActorContext.attach(
          ctx.seeded.user,
          ActorContext.build(ctx.seeded.user, tenant: Estate.organization_id())
        )

      # The claim on the marketing page is that nothing about being designed at
      # runtime stops a table updating itself. This is that claim: the same
      # data-only rebuild a declared surface gets, over a composed one.
      data_model =
        AshA2ui.Dynamic.build_data_model(composed!(),
          actor: admin,
          tenant: Estate.organization_id()
        )

      assert Map.has_key?(data_model, "updateDataModel")

      # And it subscribes to the same topics, because they come off the resource
      # rather than off the surface.
      assert Host.dynamic(composed!(), "Logins").topics ==
               Host.declared(Surfaces.fetch("legacy_users")).topics
    end
  end

  describe "the console" do
    test "opens a declared surface without a model call", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agent")

      refute render(view) =~ ~s(data-role="surface")

      html = view |> element("#open-legacy_users") |> render_click()

      assert html =~ ~s(data-role="surface")
      assert html =~ "Legacy users"

      # The "live" badge is a promise to the person reading the page, so it is
      # only rendered where it can be kept. Asserted on the tooltip rather than
      # the word, which appears in half the framework's own markup.
      assert html =~ "This surface updates itself"

      assert_push_event(view, "a2ui:messages", %{messages: messages})
      assert JSON.encode!(messages) =~ "Alan Whitfield"
    end

    test "a surface with no publications is not badged live", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agent")

      html = view |> element("#open-users") |> render_click()

      assert html =~ "Users"
      refute html =~ "This surface updates itself"
    end

    test "the shown surface refreshes and cues when the rows change", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agent")

      view |> element("#open-legacy_users") |> render_click()
      assert_push_event(view, "a2ui:messages", %{messages: _})

      # Exactly what Ash.Notifier.PubSub emits when the strangler listener
      # dispatches a write made by the legacy application.
      AshEnterpriseWeb.Endpoint.broadcast!("legacy_users:created", "legacy_write", %{})

      assert_push_event(view, "a2ui:messages", %{messages: [refresh]}, 2_000)
      assert Map.has_key?(refresh, "updateDataModel")

      assert render(view) =~ "Another application changed these rows"
    end

    test "dismissing unsubscribes, so a later write refreshes nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agent")

      view |> element("#open-legacy_users") |> render_click()
      assert_push_event(view, "a2ui:messages", %{messages: _})

      view |> element("button", "Dismiss") |> render_click()
      refute render(view) =~ ~s(data-role="surface")

      AshEnterpriseWeb.Endpoint.broadcast!("legacy_users:created", "legacy_write", %{})

      # Without the unsubscribe, asking for three surfaces in a row leaves the
      # console listening to all three and a write to any of them rebuilds a
      # surface nobody is looking at.
      refute_push_event(view, "a2ui:messages", %{}, 500)
    end

    test "switching surfaces drops the previous subscription", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agent")

      view |> element("#open-legacy_users") |> render_click()
      assert_push_event(view, "a2ui:messages", %{messages: _})

      view |> element("#open-roles") |> render_click()
      assert_push_event(view, "a2ui:messages", %{messages: _})

      AshEnterpriseWeb.Endpoint.broadcast!("legacy_users:created", "legacy_write", %{})

      refute_push_event(view, "a2ui:messages", %{}, 500)
      refute render(view) =~ "Another application changed these rows"
    end

    test "an action envelope with nothing shown is ignored rather than guessed at",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agent")

      # Rebuilding a surface from something the client echoed back is the
      # tamper-proofing hole the server-held presentation exists to close.
      assert render_hook(view, "a2ui:action", %{"action" => %{"name" => "whatever"}})
      refute render(view) =~ ~s(data-role="surface")
    end

    test "a viewer outside the legacy tenant sees the surface with none of its rows",
         %{conn: conn} do
      greenfield =
        AshEnterprise.Platform.Seeder.seed_tenant(
          unique_name: "greenfield-agent-#{System.unique_integer([:positive])}"
        )

      {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(greenfield.user)

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_token", token)

      {:ok, view, _html} = live(conn, "/agent")

      view |> element("#open-legacy_users") |> render_click()

      assert_push_event(view, "a2ui:messages", %{messages: messages})

      # The surface is built by running the resource's own read action with this
      # user as the actor, so what the agent can show is bounded by what the
      # person asking is allowed to see -- not by what the agent knows.
      refute JSON.encode!(messages) =~ "Alan Whitfield"
    end
  end
end
