defmodule AshEnterpriseWeb.ShowcaseTourIndexLiveTest do
  @moduledoc """
  The credentialing tour's index and its links, in recorded mode, on an instance whose fault
  panel is off and whose demo tenant was given its history (`mix ash_enterprise.demo
  --history`, `AshEnterprise.Showcase.History`): what a viewer of the shared instance gets.

    * the F1–F12 index links every failure to its beat, and to its record in the explorer
      when there is one; a failure with no record says so, and no link opens an empty page;
    * every beat opens its record in the explorer, or says it has none;
    * beats 2, 3 and 13 open the review packet, beat 5 the recovery surface, beat 18 the
      shadow run;
    * a beat whose record the history made says so instead of the demo-build note.

  SYNTHETIC data only.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  # The clinic's demo data ingests its licence documents into the evidence store.
  @moduletag evidence: true

  import Phoenix.LiveViewTest
  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshEnterprise.Credentialing.DemoData
  alias AshEnterprise.Faults
  alias AshEnterprise.Platform.DemoTenant
  alias AshEnterprise.Quality
  alias AshEnterprise.Showcase
  alias AshEnterprise.Showcase.History
  alias AshEnterpriseWeb.ShowcaseLive.TourIndex

  @tour "/app/showcase/credentialing"
  @fault_beats ~w(beat-stale beat-revoked beat-reconciled beat-timeout beat-webhook beat-routing beat-deploy)

  setup do
    TestJobs.clear()
    on_exit(&Faults.disarm_all/0)

    previous = Application.get_env(:ash_enterprise, Showcase)
    Application.put_env(:ash_enterprise, Showcase, Keyword.put(previous, :fault_controls?, false))
    on_exit(fn -> Application.put_env(:ash_enterprise, Showcase, previous) end)
    :ok
  end

  defp sign_in(user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp href(view, selector) do
    [href] =
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("href")

    href
  end

  # An explorer link opens a trace with something on it: never an empty page.
  defp assert_trace!(conn, path) do
    assert "/app/explorer?" <> _query = path
    {:ok, explorer, _html} = live(conn, path)
    assert has_element?(explorer, "#explorer-timeline")
    assert has_element?(explorer, "#entry-0"), "#{path} opened an empty trace"
    refute has_element?(explorer, "#timeline-empty")
    explorer
  end

  # A deep link lands on its surface with the record, not on the launcher's "not found".
  defp assert_lands!(conn, path, surface) do
    conn = get(conn, path)
    flash = Phoenix.Flash.get(conn.assigns.flash, :error)
    assert redirected_to(conn) =~ surface, "#{path}: #{inspect(flash)}"
    refute flash
  end

  defp settle!(rounds \\ 12)
  defp settle!(0), do: :ok

  defp settle!(rounds) do
    steps = Oban.drain_queue(queue: :agent_runs, with_recursion: true)
    calls = Oban.drain_queue(queue: :execution, with_recursion: true)

    if steps.success + steps.failure + calls.success + calls.failure > 0,
      do: settle!(rounds - 1),
      else:
        AshOban.Test.schedule_and_run_triggers({Quality.SuiteRun, :finish}, drain_queues?: true)
  end

  describe "with the history seeded" do
    setup do
      %{organization: demo, clinic: clinic} = DemoTenant.run!()
      report = History.run!(demo)
      assert History.complete?(report)
      %{demo: demo, clinic: clinic, report: Map.new(report, &{&1.beat, &1.ref})}
    end

    test "the index links every failure to its beat and its record, and says which have none",
         %{clinic: clinic} do
      conn = sign_in(clinic.coordinator)
      {:ok, view, _html} = live(conn, @tour)
      assert has_element?(view, "#tour-index")

      recorded = ~w(F1 F2 F3 F4 F5 F6 F7 F10)

      for {failure, number, id} <- TourIndex.failures() do
        assert href(view, "#index-#{failure}-beat") == "##{id}"
        assert has_element?(view, "##{id}"), "#{failure}'s beat #{number} is not on the page"

        if failure in recorded do
          assert has_element?(view, "#index-#{failure}[data-recorded=true]")
          refute has_element?(view, "#index-#{failure}-none")
          assert_trace!(conn, href(view, "#index-#{failure}-explore"))
        else
          # Not part of the history: the index says so, with no link to follow.
          assert has_element?(view, "#index-#{failure}[data-recorded=false]")
          assert has_element?(view, "#index-#{failure}-none", "No record yet")
          refute has_element?(view, "#index-#{failure}-explore")
        end
      end
    end

    test "every beat opens its record in the explorer or says it has none", %{clinic: clinic} do
      conn = sign_in(clinic.coordinator)
      {:ok, view, _html} = live(conn, @tour)

      for {number, id, _failure} <- TourIndex.beats() do
        link? = has_element?(view, "##{id} #explore-#{number}")
        none? = has_element?(view, "##{id} #explore-#{number}-none")
        assert link? != none?, "beat #{number} shows both or neither"
        if link?, do: assert_trace!(conn, href(view, "#explore-#{number}"))
      end

      # The rows carry their own links too.
      assert has_element?(view, "#stale-rows a[id^=stale-explore-][href^='/app/explorer?']")

      assert has_element?(
               view,
               "#timed-out-rows a[id^=timed-out-explore-][href^='/app/explorer?']"
             )

      assert has_element?(view, "#webhooks-rows a[id^=webhooks-explore-][href^='/app/explorer?']")
    end

    test "the history's beats show their records instead of the demo-build note", %{
      clinic: clinic
    } do
      {:ok, view, _html} = live(sign_in(clinic.coordinator), @tour)

      refute has_element?(view, "#fault-panel")

      for beat <- @fault_beats do
        refute has_element?(view, "##{beat} .demo-build-note"),
               "#{beat} still says demo build only"

        assert has_element?(view, "##{beat} .history-note")
      end

      # The variant that cannot be recorded beforehand says exactly why.
      assert has_element?(
               view,
               "#beat-reconciled #kill-variant-note",
               "memory of the application node"
             )
    end

    test "every approval and packet link a viewer is shown opens for that viewer", ctx do
      %{clinic: clinic, demo: demo} = ctx
      [member | _] = clinic.committee
      admin = AshEnterprise.Credentialing.LicenceDemoData.user!(DemoTenant.admin_email(), demo.id)

      for user <- [clinic.coordinator, member, admin] do
        {:ok, view, html} = live(sign_in(user), @tour)

        for [id] <-
              Regex.scan(~r/id="([a-z-]+-(?:approve|packet)-[0-9a-f-]{36})"/, html,
                capture: :all_but_first
              ) do
          assert_lands!(sign_in(user), href(view, "##{id}"), "/app/approvals")
        end
      end
    end

    test "beats 2, 3 and 13 open the review packet; beat 5 the recovery surface", ctx do
      %{clinic: clinic, demo: demo, report: report} = ctx
      [member | _] = clinic.committee
      admin = AshEnterprise.Credentialing.LicenceDemoData.user!(DemoTenant.admin_email(), demo.id)

      # The coordinator who asked cannot open a committee's approval, so is shown no link to it.
      {:ok, coordinator, _html} = live(sign_in(clinic.coordinator), @tour)
      refute has_element?(coordinator, "a[id^=awaiting-approve-]")
      refute has_element?(coordinator, "a[id^=stale-waiting-packet-]")
      refute has_element?(coordinator, "a[id^=reviews-packet-]")

      # 2: the seeded request that waits for the committee, as a member of it sees it.
      {:ok, view, _html} = live(sign_in(member), @tour)

      [awaiting | _] =
        Regex.run(~r/id="awaiting-approve-([0-9a-f-]{36})"/, render(view),
          capture: :all_but_first
        )

      assert_lands!(
        sign_in(member),
        href(view, "#awaiting-approve-#{awaiting}"),
        "/app/approvals"
      )

      # 3: a waiting request's packet, opened before approving, where the change shows ...
      assert_lands!(
        sign_in(member),
        href(view, "#stale-waiting-packet-#{awaiting}"),
        "/app/approvals"
      )

      # ... and the request that went stale: its packet is the approval it was decided on,
      # which the clinic's administrator reads once nobody is asked to act on it.
      "invocation:" <> f4 = report[3]
      {:ok, admin_view, _html} = live(sign_in(admin), @tour)
      assert href(admin_view, "#stale-packet-#{f4}") =~ "/app/r/approvals/"
      assert_lands!(sign_in(admin), href(admin_view, "#stale-packet-#{f4}"), "/app/approvals")

      # 13: the case that moved on to the committee after its document arrived.
      "process_instance:" <> case_id = report[12]
      assert_lands!(sign_in(member), href(view, "#reviews-packet-#{case_id}"), "/app/approvals")

      # 5: the request whose outcome is unknown is settled on the recovery surface.
      "invocation:" <> f2 = report[5]
      assert href(coordinator, "#reconciled-recover-#{f2}") == "/app/recovery/#{f2}"

      {:ok, recovery, _html} = live(sign_in(admin), "/app/recovery/#{f2}")
      assert has_element?(recovery, "#status[data-status=uncertain]")
      assert has_element?(recovery, "#settle-form")
    end

    test "beat 18 opens the shadow run", %{clinic: clinic} do
      conn = sign_in(clinic.director)
      {:ok, view, _html} = live(conn, @tour)
      assert has_element?(view, "#index-F12-none")

      view |> element("#run-shadow") |> render_click()
      settle!()
      send(view.pid, :refresh)
      render(view)

      [id] =
        Regex.run(~r/id="shadow-([0-9a-f-]{36})-open-1"/, render(view), capture: :all_but_first)

      assert_trace!(conn, href(view, "#shadow-#{id}-open-1"))
      assert_trace!(conn, href(view, "#index-F12-explore"))
    end
  end

  describe "without the history" do
    setup do
      admin = tenant!()
      %{clinic: DemoData.populate(admin.tenant)}
    end

    test "a failure with no record says so, and its beat keeps the demo-build note", %{
      clinic: clinic
    } do
      {:ok, view, _html} = live(sign_in(clinic.coordinator), @tour)

      for failure <- ~w(F1 F2 F3 F4 F5 F6 F7 F10) do
        assert has_element?(view, "#index-#{failure}-none", "No record yet")
        refute has_element?(view, "#index-#{failure}-explore")
      end

      for beat <- @fault_beats do
        assert has_element?(view, "##{beat} .demo-build-note", "demo build only")
        refute has_element?(view, "##{beat} .history-note")
      end
    end

    test "an explorer link whose record has gone shows that, not a blank page", %{clinic: clinic} do
      conn = sign_in(clinic.coordinator)
      path = TourIndex.explorer_path({:invocation, Ecto.UUID.generate()})
      {:ok, explorer, html} = live(conn, path)

      assert html =~ ~s(id="explorer-timeline")

      assert has_element?(explorer, "#timeline-empty") or
               has_element?(explorer, "#explorer-error")
    end
  end

  describe "records/1" do
    @empty %{
      activations: [],
      readings: [],
      cases: [],
      release: %{candidate: nil, shadow: [], routing: %{table_version: nil, cases: []}}
    }

    test "nothing read is no record, for every beat" do
      assert TourIndex.records(@empty) == Map.new(1..19, &{&1, nil})
    end

    test "a release that was not read, and rows in states it does not know, are no record" do
      unknown = %{
        invocation: %{id: "i", status: :pondering, error_code: nil, reconciled_via: nil},
        credential_id: nil
      }

      records =
        TourIndex.records(%{
          @empty
          | activations: [unknown],
            release: %{candidate: %{run: nil}, shadow: nil, routing: nil}
        })

      # A request in an unknown state is the record of no failure (it is still a request).
      for beat <- [2, 3, 4, 5, 15, 16, 17, 18, 19], do: assert(records[beat] == nil)
      assert records[1] == {:invocation, "i"}
    end

    test "a stale request is the record of the failure its reason names, and no other" do
      stale = fn id, code ->
        %{invocation: %{id: id, status: :stale, error_code: code, reconciled_via: nil}}
      end

      records =
        TourIndex.records(%{
          @empty
          | activations: [stale.("a", "subject_changed"), stale.("b", "manifest_changed")]
        })

      assert records[3] == {:invocation, "a"}
      assert records[19] == {:invocation, "b"}

      records = TourIndex.records(%{@empty | activations: [stale.("c", nil)]})
      assert records[3] == nil and records[19] == nil
    end
  end
end
