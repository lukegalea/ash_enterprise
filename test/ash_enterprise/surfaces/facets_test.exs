defmodule AshEnterprise.Surfaces.FacetsTest do
  @moduledoc """
  The registry's `audience` and `searchable` facets.

    * Reviewers, builders and operators each get their own launcher: the
      registry's audience views differ, and `/app?for=<audience>` shows that
      view. An unknown audience shows everything.
    * A clinic case is found by its business reference (the credential's
      licence number) and by its run id (the case's process run), as the person
      searching. A record they may not read is not found, and a surface that
      could not be searched is reported, never read as "no match".
  """

  use AshEnterpriseWeb.ConnCase, async: false

  # The clinic's demo data ingests its licence documents into the evidence store.
  @moduletag evidence: true

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]
  import Phoenix.LiveViewTest

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.DemoData
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Showcase.Case, as: Tour
  alias AshEnterprise.Surfaces
  alias AshEnterprise.Surfaces.{Search, Surface}

  defp keys(audience),
    do: Surfaces.all() |> Surfaces.for_audience(audience) |> MapSet.new(& &1.key)

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  describe "audience" do
    test "every surface is for one or more of the four audiences" do
      known = Keyword.keys(Surfaces.audiences())

      for surface <- Surfaces.all() do
        assert surface.audience != [], inspect(surface.key)
        assert Enum.all?(surface.audience, &(&1 in known)), inspect(surface.key)
      end
    end

    test "the reviewer, builder and operator launchers differ" do
      reviewer = keys(:reviewer)
      builder = keys(:builder)
      operator = keys(:operator)

      assert reviewer != builder and builder != operator and reviewer != operator

      # A reviewer decides on findings and verdicts; a builder shapes processes
      # and rules; an operator runs syncs, lineage and accounts.
      assert :findings in reviewer and :judgment_verdicts in reviewer
      refute :findings in builder or :processes in reviewer
      assert :processes in builder and :rule_sets in builder and :mdm_mappings in builder
      assert :lineage in operator and :users in operator
      refute :lineage in reviewer or :lineage in builder

      # Everyone's view is everything.
      assert Surfaces.for_audience(Surfaces.all(), nil) == Surfaces.all()
    end

    test "an unknown or missing audience name is everyone, and makes no atom" do
      assert Surfaces.audience("reviewer") == :reviewer
      assert Surfaces.audience("nobody-#{System.unique_integer([:positive])}") == nil
      assert Surfaces.audience("") == nil
      assert Surfaces.audience(nil) == nil
    end

    test "/app?for= shows that audience's launcher", %{conn: conn} do
      admin = tenant!()
      conn = sign_in(conn, admin.user)

      {:ok, view, _html} = live(conn, "/app?for=builder")
      assert has_element?(view, "#launch-processes")
      refute has_element?(view, "#launch-judgment_verdicts")
      refute has_element?(view, "#launch-users")
      assert has_element?(view, "#launch-for-builder[aria-current=page]")

      {:ok, view, _html} = live(conn, "/app?for=reviewer")
      assert has_element?(view, "#launch-judgment_verdicts")
      refute has_element?(view, "#launch-processes")

      {:ok, view, _html} = live(conn, "/app?for=operator")
      assert has_element?(view, "#launch-users")
      refute has_element?(view, "#launch-processes")

      # Unknown: everything, as on /app.
      {:ok, view, _html} = live(conn, "/app?for=nobody")
      assert has_element?(view, "#launch-processes")
      assert has_element?(view, "#launch-users")
      assert has_element?(view, "#launch-for-all[aria-current=page]")
    end
  end

  describe "searchable" do
    setup do
      TestJobs.clear()
      admin = tenant!()
      clinic = DemoData.populate(admin.tenant)
      user = clinic.coordinator
      coordinator = ActorContext.attach(user, ActorContext.build(user, tenant: admin.tenant))
      credential = clinic.case_credential
      Credentialing.open_case!(credential.id, actor: coordinator, tenant: admin.tenant)
      kase = Enum.find(Tour.cases(coordinator), &(&1.credential.id == credential.id))

      %{
        admin: admin,
        coordinator: coordinator,
        user: user,
        credential: credential,
        run: kase.instance
      }
    end

    test "a searchable attribute is the resource's, on a surface with a detail" do
      for %Surface{searchable: [_ | _]} = surface <- Surfaces.all() do
        assert surface.context, inspect(surface.key)

        for field <- surface.searchable do
          assert Ash.Resource.Info.attribute(surface.resource, field),
                 "#{surface.key}: #{field}"
        end
      end
    end

    test "a clinic case is found by its business reference",
         %{coordinator: coordinator, credential: credential} do
      assert %{hits: hits, failed: []} = Search.find(credential.number, coordinator)

      assert %{field: :number, path: path} =
               Enum.find(hits, &(&1.surface.key == :credentials and &1.id == credential.id))

      assert path == "/app/r/credentials/#{credential.id}"

      # A licence number is never compared with a run id.
      refute Enum.any?(hits, &(&1.surface.key in [:flight, :lineage]))
    end

    test "a clinic case is found by its run id, by whoever may read the run",
         %{admin: admin, coordinator: coordinator, credential: credential, run: run} do
      assert %{hits: [hit], failed: []} = Search.find(run.id, admin.actor)
      assert %{surface: %{key: :flight}, field: :id} = hit
      assert hit.id == run.id
      assert hit.path == "/app/r/flight/#{run.id}"

      # The administrator finds the case's credential by its reference too.
      assert %{hits: hits, failed: []} = Search.find(credential.number, admin.actor)
      assert Enum.any?(hits, &(&1.surface.key == :credentials and &1.id == credential.id))

      # The coordinator's policies do not reach the process run: not found, not an error.
      assert Search.find(run.id, coordinator) == %{hits: [], failed: []}
    end

    test "nothing typed reads nothing, and an unknown reference finds nothing",
         %{coordinator: coordinator} do
      assert Search.find("", coordinator) == %{hits: [], failed: []}
      assert Search.find("   ", coordinator) == %{hits: [], failed: []}
      assert Search.find(nil, coordinator) == %{hits: [], failed: []}

      assert Search.find("NO-SUCH-LICENCE", coordinator) == %{hits: [], failed: []}
      assert Search.find(Ash.UUID.generate(), coordinator) == %{hits: [], failed: []}
    end

    test "another clinic's case is not found", %{credential: credential, run: run} do
      other = tenant!()

      assert %{hits: [], failed: []} = Search.find(credential.number, other.actor)
      assert %{hits: [], failed: []} = Search.find(run.id, other.actor)
    end

    test "a surface that could not be searched is reported, not read as no match",
         %{coordinator: coordinator, credential: credential} do
      broken = %{Surfaces.fetch!(:credentials) | searchable: [:no_such_attribute]}

      assert %{hits: [], failed: [%Surface{key: :credentials}]} =
               Search.find(credential.number, coordinator, [broken])

      # The others still answer beside it.
      assert %{hits: [_], failed: [_]} =
               Search.find(credential.number, coordinator, [broken, Surfaces.fetch!(:credentials)])
    end

    test "Enter on the launcher opens the case found by its reference or its run",
         %{conn: conn, admin: admin, credential: credential, run: run} do
      conn = sign_in(conn, admin.user)

      {:ok, view, _html} = live(conn, "/app")

      assert {:error, {:redirect, %{to: to}}} =
               view |> form("#launch-filter", launch: %{q: credential.number}) |> render_submit()

      assert to == "/app/r/credentials/#{credential.id}"

      {:ok, view, _html} = live(conn, "/app")

      assert {:error, {:redirect, %{to: to}}} =
               view |> form("#launch-filter", launch: %{q: run.id}) |> render_submit()

      assert to == "/app/r/flight/#{run.id}"

      # Nothing found: the page says so and stays.
      {:ok, view, _html} = live(conn, "/app")
      view |> form("#launch-filter", launch: %{q: "NO-SUCH-LICENCE"}) |> render_submit()
      assert has_element?(view, "#launch-no-match")
      refute has_element?(view, "#launch-search-failed")
    end
  end
end
