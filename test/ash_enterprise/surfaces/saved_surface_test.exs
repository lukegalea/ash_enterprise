defmodule AshEnterprise.Surfaces.SavedSurfaceTest do
  @moduledoc """
  A saved surface (a pinned app, `AshEnterprise.Assistant.PinnedApp`) reopened
  later: read under the viewer's grants as they are now (DS-03); whether its
  definition still resolves and how fresh its rows are, shown as two states
  (DS-02); built in the catalog the client renders, or the declared fallback
  for a client that renders none (DS-04); and never able to carry an
  operation a composed view does not declare (DS-01). Clinic data, SYNTHETIC.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshEnterprise.Assistant.{Composer, PinnedApp}
  alias AshEnterprise.Canonical.Person
  alias AshEnterprise.Security
  alias AshEnterprise.Surfaces.{ClientCatalog, SavedStatus}
  alias AshEnterprise.Test.DailyFixtures, as: D

  @admin_catalog "https://ash-a2ui.dev/catalogs/admin/v1"
  @basic_catalog "https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json"

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  # A front-desk member who reads their own patients' contact records, and
  # one more that a colleague shared with them: the grant the tests take away.
  setup %{conn: conn} do
    admin = D.tenant!()

    member =
      D.member!(admin, "Front desk #{System.unique_integer([:positive])}", [
        {Person, :read, :basic}
      ])

    n = System.unique_integer([:positive])
    ada = D.person!(admin, "ada-#{n}@clinic.example", "SYNTHETIC Ada Lin")
    D.person!(member, "bea-#{n}@clinic.example", "SYNTHETIC Bea Moss")

    %{
      conn: sign_in(conn, member.user),
      admin: admin,
      member: member,
      share: share!(admin, member, ada)
    }
  end

  defp share!(admin, member, person) do
    Security.AccessGrant
    |> Ash.Changeset.for_create(:share, %{
      principal_id: member.user.id,
      principal_type: :user,
      resource_name: inspect(Person),
      record_id: person.id,
      rights_mask: Security.AccessRight.to_mask([:read])
    })
    |> Ash.create!(tenant: admin.tenant, authorize?: false)
  end

  defp revoke!(admin, share) do
    share
    |> Ash.Changeset.for_update(:revoke_direct, %{})
    |> Ash.update!(tenant: admin.tenant, authorize?: false)
  end

  defp people_spec do
    {:ok, composed} = Composer.compose(%{show: "people"})
    AshA2ui.Dynamic.serialize(composed.surface)
  end

  defp pin!(member, spec \\ people_spec()) do
    PinnedApp.pin!(
      %{title: "People", display: :table, source: "people", spec: spec},
      actor: member.actor,
      tenant: member.tenant
    )
  end

  # A pin stored as it was before today's schema: written straight to the
  # data layer, as a row saved by an earlier release would be, so the pin
  # action's own check does not stop it.
  defp stored!(member, spec) do
    Ash.Seed.seed!(
      PinnedApp,
      %{
        title: "People",
        display: :table,
        source: "people",
        spec: spec,
        owner_id: member.user.id,
        owner_type: :user,
        owning_user_id: member.user.id,
        owning_business_unit_id: member.user.owning_business_unit_id
      },
      tenant: member.tenant
    )
  end

  # The serialized form (`AshA2ui.Dynamic.serialize/1`) holds the spec under "spec".
  defp edit_spec(serialized, fun),
    do: serialized |> Jason.decode!() |> Map.update!("spec", fun) |> Jason.encode!()

  defp table(spec, fun) do
    edit_spec(spec, fn decoded ->
      update_in(decoded, ["components"], fn [table | rest] -> [fun.(table) | rest] end)
    end)
  end

  defp open!(conn, app) do
    {:ok, view, _html} = live(conn, "/app/mine/#{app.id}")
    _ = render_async(view, 10_000)
    view
  end

  defp pushed!(view) do
    assert_push_event(view, "a2ui:messages", %{messages: messages}, 5_000)
    Jason.encode!(messages)
  end

  describe "reopened after a grant is revoked (DS-03)" do
    test "the pinned app shows less: the revoked rows are not sent, not just flagged",
         %{conn: conn, admin: admin, member: member, share: share} do
      app = pin!(member)

      before = conn |> open!(app) |> pushed!()
      assert before =~ "SYNTHETIC Ada Lin"
      assert before =~ "SYNTHETIC Bea Moss"

      # The stored definition holds no rows and no grant: nothing to freeze.
      refute app.spec =~ "SYNTHETIC"

      revoke!(admin, share)

      view = open!(conn, app)
      reopened = pushed!(view)

      refute reopened =~ "SYNTHETIC Ada Lin"
      assert reopened =~ "SYNTHETIC Bea Moss"
      # Still a valid definition: losing a grant hides rows, it does not break the view.
      assert has_element?(view, "#pinned-validity[data-validity=valid]")
    end

    test "a grant revoked while it is open hides its rows at the next refresh",
         %{conn: conn, admin: admin, member: member, share: share} do
      view = open!(conn, pin!(member))
      assert pushed!(view) =~ "SYNTHETIC Ada Lin"

      revoke!(admin, share)
      send(view.pid, {:ash_a2ui_host, :refresh})

      refreshed = pushed!(view)
      refute refreshed =~ "SYNTHETIC Ada Lin"
      assert refreshed =~ "SYNTHETIC Bea Moss"
    end

    test "Read again reads under the grants held now",
         %{conn: conn, admin: admin, member: member, share: share} do
      view = open!(conn, pin!(member))
      assert pushed!(view) =~ "SYNTHETIC Ada Lin"

      revoke!(admin, share)
      view |> element("#reread") |> render_click()

      refute pushed!(view) =~ "SYNTHETIC Ada Lin"
    end
  end

  describe "validity and freshness are two states (DS-02)" do
    test "a valid definition with rows just read: valid, and fresh, in two badges",
         %{conn: conn, member: member} do
      view = open!(conn, pin!(member))
      _ = pushed!(view)

      assert has_element?(view, "#pinned-validity[data-validity=valid]", "Definition valid")
      assert has_element?(view, "#pinned-freshness[data-freshness=fresh]", "Data read at")
      refute has_element?(view, "#pinned-validity[data-freshness]")
      refute has_element?(view, "#pinned-freshness[data-validity]")
    end

    test "a definition that no longer resolves reads invalid, never valid but empty",
         %{conn: conn, member: member} do
      renamed =
        table(people_spec(), fn table ->
          Map.update!(table, "fields", fn fields -> ["phone_extension" | fields] end)
        end)

      view = open!(conn, stored!(member, renamed))

      assert has_element?(view, "#pinned-validity[data-validity=invalid]", "Definition invalid")
      refute has_element?(view, "#pinned-validity[data-validity=valid]")
      assert has_element?(view, "#pinned-refused")
      # No rows were read, so how old they are is unknown, never fresh.
      assert has_element?(view, "#pinned-freshness[data-freshness=unknown]", "freshness unknown")
      refute has_element?(view, "#reread")
      refute_push_event(view, "a2ui:messages", %{}, 200)
    end

    test "a stored text that is not a spec at all reads invalid", %{conn: conn, member: member} do
      view = open!(conn, stored!(member, "{\"resource\":\"people\""))

      assert has_element?(view, "#pinned-validity[data-validity=invalid]")
      assert has_element?(view, "#pinned-freshness[data-freshness=unknown]")
      refute_push_event(view, "a2ui:messages", %{}, 200)
    end

    test "validity is only valid for a resolved surface" do
      {:ok, surface} = Composer.reload(people_spec())

      assert SavedStatus.validity({:ok, surface}) == :valid
      assert SavedStatus.validity({:error, ["gone"]}) == :invalid
      # errored without reasons, unmeasured, missing, unknown
      assert SavedStatus.validity({:error, []}) == :invalid
      assert SavedStatus.validity(nil) == :unknown
      assert SavedStatus.validity({:ok, nil}) == :unknown
      assert SavedStatus.validity({:ok, %{}}) == :unknown
      assert SavedStatus.validity({:exit, :timeout}) == :unknown
      assert SavedStatus.validity(:valid) == :unknown
    end

    test "freshness is unknown, never fresh, without a usable read time" do
      now = DateTime.utc_now()

      assert SavedStatus.freshness(now, now) == :fresh
      assert SavedStatus.freshness(DateTime.add(now, -60), now) == :fresh

      assert SavedStatus.freshness(DateTime.add(now, -(SavedStatus.fresh_seconds() + 1)), now) ==
               :stale

      # never read, malformed, from a clock ahead of ours, no clock to judge by
      assert SavedStatus.freshness(nil, now) == :unknown
      assert SavedStatus.freshness("2026-11-07T10:00:00Z", now) == :unknown
      assert SavedStatus.freshness(~N[2026-11-07 10:00:00], now) == :unknown
      assert SavedStatus.freshness(DateTime.add(now, 120), now) == :unknown
      assert SavedStatus.freshness(now, nil) == :unknown
    end
  end

  describe "a client without the catalog gets the declared fallback (DS-04)" do
    defp caps(ids), do: %{"v1.0" => %{"supportedCatalogIds" => ids}}

    defp build_for(member, capabilities) do
      {:ok, surface} = Composer.reload(people_spec())

      with {:ok, catalog} <- ClientCatalog.build_opts(capabilities) do
        {:ok,
         AshA2ui.Dynamic.build_surface(
           surface,
           [actor: member.actor, tenant: member.tenant, authorize?: true] ++ catalog
         )}
      end
    end

    defp catalog_id([%{"createSurface" => %{"catalogId" => id}} | _]), do: id

    test "a client listing the admin catalog gets it; the web, sending none, too",
         %{member: member} do
      assert {:ok, messages} = build_for(member, caps([@admin_catalog]))
      assert catalog_id(messages) == @admin_catalog

      assert {:ok, messages} = build_for(member, nil)
      assert catalog_id(messages) == @admin_catalog
    end

    test "a client with only the basic catalog gets the basic composition", %{member: member} do
      assert {:ok, messages} =
               build_for(
                 member,
                 caps(["https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"])
               )

      assert catalog_id(messages) == @basic_catalog
      refute Jason.encode!(messages) =~ "entityPage"
      assert Jason.encode!(messages) =~ "SYNTHETIC Bea Moss"
    end

    test "a client that renders none of them gets the fallback, never the basic catalog",
         %{member: member} do
      for capabilities <- [
            caps([]),
            caps(["https://example.com/catalogs/clinic-kiosk.json"]),
            %{"v1.0" => %{}},
            %{"v1.0" => %{"supportedCatalogIds" => "basic"}},
            %{},
            "basic"
          ] do
        assert build_for(member, capabilities) == :fallback,
               "#{inspect(capabilities)} was read as a catalog the client renders"
      end

      fallback = ClientCatalog.fallback("People", "/app/people")
      assert fallback["reason"] == "unsupported_catalog"
      assert fallback["message"] =~ "/app/people"
    end
  end

  describe "a composed view cannot reference an undeclared action (DS-01)" do
    defp refused?(spec, member) do
      pinned =
        PinnedApp.pin(%{title: "People", display: :table, source: "people", spec: spec},
          actor: member.actor,
          tenant: member.tenant
        )

      assert {:error, %Ash.Error.Invalid{}} = pinned
      assert {:error, [_ | _]} = Composer.reload(spec)
    end

    test "a row action, even one the resource declares, is refused when pinned and on reopen",
         %{conn: conn, member: member} do
      spec = table(people_spec(), &Map.put(&1, "row_actions", ["mdm_unmerge"]))
      refused?(spec, member)

      view = open!(conn, stored!(member, spec))
      assert has_element?(view, "#pinned-validity[data-validity=invalid]")
      assert render(view) =~ "row actions"
      refute_push_event(view, "a2ui:messages", %{}, 200)
    end

    test "an action the resource does not declare is refused", %{member: member} do
      table(people_spec(), &Map.put(&1, "row_actions", ["prescribe"])) |> refused?(member)
    end

    test "a form is refused", %{member: member} do
      people_spec()
      |> edit_spec(fn spec ->
        Map.update!(spec, "components", &(&1 ++ [%{"kind" => "form", "fields" => ["name"]}]))
      end)
      |> refused?(member)
    end

    test "a read action the catalogue does not offer is refused", %{member: member} do
      table(people_spec(), &Map.put(&1, "read_action", "goldens")) |> refused?(member)
    end

    test "every view the composer writes is approved" do
      for source <- Composer.sources(),
          display <- Composer.displays(),
          extra <- [%{}, %{window: "today"}, %{channel: "gmail"}, %{channel: "slack"}] do
        case Composer.compose(Map.merge(%{show: source, display: display}, extra)) do
          {:ok, composed} -> assert {:ok, _} = Composer.approved(composed.surface)
          {:error, _not_offered} -> :ok
        end
      end
    end
  end
end
