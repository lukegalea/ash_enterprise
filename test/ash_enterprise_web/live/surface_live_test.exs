defmodule AshEnterpriseWeb.SurfaceLiveTest do
  @moduledoc """
  The thin surface pages are generated from the registry
  (`AshEnterpriseWeb.SurfaceLive`), and every hand-written renderer is a
  declared specialist (`renderer: :specialist` in `AshEnterprise.Surfaces`).
  A renderer written by hand and not declared fails here.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import AshEnterprise.Test.DailyFixtures
  import Phoenix.LiveViewTest

  alias AshEnterprise.Surfaces
  alias AshEnterprise.Surfaces.Surface

  # A renderer written by hand and declared nowhere: what the guard must catch.
  defmodule StrayThin do
    @moduledoc false
    use AshA2ui.LiveRenderer, ui: AshEnterpriseWeb.A2ui.UserUI
  end

  # The addresses the thin pages were served at before they were generated.
  # They must keep working.
  @thin_paths ~w(
    /app/users /app/teams /app/roles /app/business-units
    /app/mdm /app/mdm/mappings /app/mdm/batches
    /app/judgments /app/judgments/band-tables /app/judgments/certifications
    /app/judgments/calibration /app/judgments/facts
    /app/tasks /app/reviews/stalled /app/credentialing
    /app/compliance/findings /app/compliance/evaluations /app/compliance/bundles
    /app/compliance/rule-sets /app/compliance/catalogs /app/compliance/profiles
  )

  @specialists ~w(
    today calendar inbox slack people action_items approvals accounts erasure
    lineage audit flight brief_flight steward_flight directory mdm_golden legacy_users
  )a

  defp renderer?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__ash_a2ui_config__, 0)
  end

  # The renderers among `modules` that are neither generated nor the LiveView of
  # an entry declared a specialist.
  defp undeclared(modules) do
    generated = MapSet.new(Surfaces.generated(), & &1.live)

    for module <- modules,
        renderer?(module),
        module not in generated,
        not match?(%Surface{renderer: :specialist}, Surfaces.by_live(module)),
        do: module
  end

  defp app_modules do
    {:ok, modules} = :application.get_key(:ash_enterprise, :modules)
    modules
  end

  describe "the guard" do
    test "every renderer the application compiles is generated or a declared specialist" do
      assert undeclared(app_modules()) == []
    end

    test "a hand-written renderer declared nowhere is caught" do
      assert undeclared([StrayThin]) == [StrayThin]
    end

    test "a specialist is a hand-written renderer, and only the reviewed ones are" do
      specialists = Enum.filter(Surfaces.all(), &(&1.renderer == :specialist))

      for surface <- specialists do
        assert renderer?(surface.live), inspect(surface.key)
        refute surface.live in Enum.map(Surfaces.generated(), & &1.live), inspect(surface.key)
      end

      # Adding a specialist is a design decision, so it is named here too.
      assert Enum.sort(Enum.map(specialists, & &1.key)) == Enum.sort(@specialists)
    end

    test "every renderer acts through the channels' action path, so its feedback says what the act came to" do
      renderers = for module <- app_modules(), renderer?(module), do: module
      assert length(renderers) > 30

      for module <- renderers do
        assert module.__ash_a2ui_config__().action_fn == (&AshEnterpriseWeb.A2ui.Host.act/3),
               "#{inspect(module)} writes /ui/feedback without the channels' result"
      end
    end

    test "a page that is not a renderer is neither generated nor a specialist" do
      for %Surface{renderer: nil} = surface <- Surfaces.all() do
        refute renderer?(surface.live), inspect(surface.key)
      end
    end
  end

  describe "the generated pages" do
    test "each renders its entry's UI, named after its key, with deep links" do
      generated = Surfaces.generated()
      assert length(generated) == 21

      for surface <- generated do
        config = surface.live.__ash_a2ui_config__()
        assert config.ui == surface.ui, inspect(surface.key)
        assert config.deep_link
        assert ["AshEnterpriseWeb", "SurfaceLive", _key] = Module.split(surface.live)
      end
    end

    test "are routed at the addresses they had before" do
      generated = Map.new(Surfaces.generated(), &{&1.path, &1.live})
      assert Enum.sort(Map.keys(generated)) == Enum.sort(@thin_paths)

      for path <- @thin_paths do
        assert %{phoenix_live_view: {view, _action, _opts, _session}} =
                 Phoenix.Router.route_info(AshEnterpriseWeb.Router, "GET", path, "")

        assert view == Map.fetch!(generated, path), path
      end
    end

    test "a signed-in person opens one, read as them", %{conn: conn} do
      admin = tenant!()
      {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(admin.user)

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_token", token)

      {:ok, view, html} = live(conn, "/app/users")

      assert html =~ "ash-a2ui-surface"
      assert_push_event(view, "a2ui:messages", %{messages: messages})
      assert JSON.encode!(messages) =~ admin.email
    end

    test "a signed-out visitor is sent to sign in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, "/app/compliance/findings")
    end

    test "a closed door refuses the page", %{conn: conn} do
      member = member!(tenant!(), "No compliance", [])
      {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(member.user)

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_token", token)

      assert {:error, {:redirect, %{to: "/app", flash: %{"error" => error}}}} =
               live(conn, "/app/compliance/findings")

      assert error =~ "Findings is for"
    end
  end
end
