defmodule AshEnterpriseWeb.ShowcaseReleaseLiveTest do
  @moduledoc """
  Showcase slice 4 through the real LiveView, in recorded mode: the credentialing tour's
  release beats (`/app/showcase/credentialing`, beats 16 to 19). The clinic director measures
  the licence reader's candidate release from the tour, and its injection case fails the gate
  (F9); the routing table changes while a case runs and the older case keeps its version
  (F10); a shadow rerun activates nobody (F12); a deploy that changes `activate_credential`
  leaves a waiting approval stale (F3).

  With the demo flag off, every beat that needs a fault control says so in place.
  The release machinery below the page is `AshEnterprise.Showcase.ReleaseSliceTest`'s.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  # The clinic's demo data ingests its licence documents into the evidence store.
  @moduletag evidence: true

  import Phoenix.LiveViewTest
  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]
  import AshEnterpriseWeb.RunCueAssertions

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Credentialing.DemoData
  alias AshEnterprise.Execution
  alias AshEnterprise.Faults
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Quality
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Showcase

  @tour "/app/showcase/credentialing"
  @fault_beats ~w(beat-routing beat-deploy)

  setup do
    TestJobs.clear()
    on_exit(&Faults.disarm_all/0)
    admin = tenant!()
    %{tenant: admin.tenant, clinic: DemoData.populate(admin.tenant)}
  end

  defp sign_in(user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp actor(user, tenant),
    do: ActorContext.attach(user, ActorContext.build(user, tenant: tenant))

  defp refreshed(view) do
    send(view.pid, :refresh)
    render(view)
    view
  end

  # What the runs' `:step` jobs and their tool calls' `:execute` jobs do, until neither
  # queue has anything left, and then the sweep that scores a suite run whose cases settled.
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

  test "16 (F9): the candidate passes the ordinary case, fails the injection case, and is refused",
       ctx do
    {:ok, view, _html} = live(sign_in(ctx.clinic.director), @tour)

    assert has_element?(view, "#model-mode", "Model mode: recorded")
    assert has_element?(view, "#candidate-none")

    view |> element("#measure-candidate") |> render_click()
    settle!()
    view = refreshed(view)

    assert has_element?(view, "#candidate[data-status=resolved][data-run=finished]")
    # The measurement is a test, and says so (QX-08).
    assert assert_test_cue(view, "#candidate") == ["offline"]
    refute_live_claim(view, "#beat-candidate")
    assert has_element?(view, "#case-plain[data-status=passed]")
    assert has_element?(view, "#case-injected[data-status=failed]")
    assert has_element?(view, "#injection-lane", "attack success rate 100%")

    html = view |> element("#request-release") |> render_click()
    assert html =~ "The release was refused."

    # Nobody was asked to approve it; the reason stays on the page and the release.
    view = refreshed(view)
    assert has_element?(view, "#candidate[data-status=resolved]")
    assert has_element?(view, "#gate-problems [data-problem]", "injection case(s) failed")
    assert has_element?(view, "#gate-problems [data-problem]", "injected")
  end

  test "18 (F12): a shadow rerun answers every call from fixtures and activates nobody", ctx do
    {:ok, view, _html} = live(sign_in(ctx.clinic.director), @tour)
    assert has_element?(view, "#shadow-none")
    before = view |> element("#active-credentials") |> render() |> active()

    view |> element("#run-shadow") |> render_click()
    settle!()
    view = refreshed(view)

    assert has_element?(view, "#shadow-rows li[data-status=finished]")
    assert Enum.uniq(assert_test_cue(view, "#shadow-rows")) == ["shadow"]
    refute_live_claim(view, "#beat-shadow")
    assert [calls, simulated] = shadow_counts(view)
    assert calls > 0 and calls == simulated

    assert view |> element("#active-credentials") |> render() |> active() == before

    assert Execution.list_invocations!(
             authorize?: false,
             tenant: ctx.tenant,
             query: [
               filter: [target: "AshEnterprise.Credentialing.Credential.activate_credential"]
             ]
           )
           |> Enum.all?(&(&1.status != :succeeded))
  end

  test "17 (F10): an older case keeps its routing table version after the table changes", ctx do
    [first, second | _] = ctx.clinic.credentials
    {:ok, view, _html} = live(sign_in(ctx.clinic.coordinator), @tour)
    assert has_element?(view, "#routing-table[data-version=\"1\"]")

    view |> element("#open-case-#{first.id}") |> render_click()
    view |> element("#fault-routing") |> render_click()
    view |> element("#open-case-#{second.id}") |> render_click()
    view = refreshed(view)

    assert has_element?(view, "#routing-table[data-version=\"2\"]")
    assert has_element?(view, "#routed-rows li[data-table-version=\"1\"]", first.number)
    assert has_element?(view, "#routed-rows li[data-table-version=\"2\"]", second.number)

    [old, new] = routed_ids(view)
    assert view |> element("#route-#{old}") |> render_click() =~ "committee by table version 1"
    assert view |> element("#route-#{new}") |> render_click() =~ "director by table version 2"
  end

  test "19 (F3): a deploy that changes activate_credential leaves the waiting approval stale",
       ctx do
    [credential | _] = ctx.clinic.credentials
    {:ok, view, _html} = live(sign_in(ctx.clinic.coordinator), @tour)

    view |> element("#raise-#{credential.id}") |> render_click()
    view = refreshed(view)

    [%{invocation: asked}] =
      Showcase.Credentialing.activations(actor(ctx.clinic.coordinator, ctx.tenant))
      |> Enum.filter(&(&1.credential_id == credential.id))

    assert has_element?(
             view,
             "#bound-#{asked.id}[data-status=awaiting_approval][data-current=true]"
           )

    view |> element("#fault-deploy") |> render_click()
    view = refreshed(view)
    assert has_element?(view, "#bound-#{asked.id}[data-current=false]", "earlier release")

    task = Ash.load!(asked, :approval_task, authorize?: false).approval_task

    HumanTask
    |> Ash.ActionInput.for_action(:approve, %{record_id: task.id},
      actor: actor(hd(ctx.clinic.committee), ctx.tenant),
      tenant: ctx.tenant
    )
    |> Ash.run_action!()

    Execution.apply_invocation_decision!(asked, actor: SystemActor.oban(), tenant: ctx.tenant)
    view = refreshed(view)

    assert has_element?(
             view,
             "#bound-#{asked.id}[data-status=stale][data-reason=manifest_changed]"
           )
  end

  test "the tour speaks French over the release beats", ctx do
    {:ok, view, _html} = live(sign_in(ctx.clinic.director), @tour <> "?locale=fr")

    assert has_element?(view, "#beat-candidate h2", "(F9)")
    assert has_element?(view, "#beat-candidate h2", "candidate")
    assert has_element?(view, "#measure-candidate", "Mesurer")

    {:ok, view, _html} = live(sign_in(ctx.clinic.director), @tour)

    assert has_element?(
             view,
             "#beat-candidate h2",
             "A candidate release fails its injection case"
           )
  end

  describe "with the demo flag off" do
    setup do
      previous = Application.get_env(:ash_enterprise, Showcase)

      Application.put_env(
        :ash_enterprise,
        Showcase,
        Keyword.put(previous, :fault_controls?, false)
      )

      on_exit(fn -> Application.put_env(:ash_enterprise, Showcase, previous) end)
    end

    test "every beat that needs a fault control says, in place, that it runs in the demo build",
         ctx do
      refute Showcase.fault_controls?()
      {:ok, view, _html} = live(sign_in(ctx.clinic.director), @tour)

      for beat <- @fault_beats do
        assert has_element?(view, "##{beat} .demo-build-note", "demo build only"),
               "#{beat} does not say it needs the demo build"
      end

      # The beats that need no control do not claim to, and still work.
      for beat <- ~w(beat-candidate beat-shadow) do
        refute has_element?(view, "##{beat} .demo-build-note")
      end

      assert has_element?(view, "#measure-candidate")
      assert has_element?(view, "#run-shadow")
      refute has_element?(view, "#fault-routing")
      refute has_element?(view, "#fault-deploy")

      for control <- ~w(routing deploy) do
        assert render_hook(view, "fault", %{"control" => control}) =~
                 "The fault panel is off here."
      end
    end

    test "the demo build note reads in French", ctx do
      {:ok, view, _html} = live(sign_in(ctx.clinic.director), @tour <> "?locale=fr")
      assert has_element?(view, "#beat-routing .demo-build-note", "version de démonstration")
      assert has_element?(view, "#beat-deploy .demo-build-note", "version de démonstration")
    end
  end

  defp active(html) do
    [count] = Regex.run(~r/data-active="(\d+)"/, html, capture: :all_but_first)
    count
  end

  defp shadow_counts(view) do
    html = view |> element("#shadow-rows li") |> render()
    [calls] = Regex.run(~r/data-calls="(\d+)"/, html, capture: :all_but_first)
    [simulated] = Regex.run(~r/data-simulated="(\d+)"/, html, capture: :all_but_first)
    [String.to_integer(calls), String.to_integer(simulated)]
  end

  # The routed cases' ids, oldest table version first.
  defp routed_ids(view) do
    view
    |> render()
    |> then(&Regex.scan(~r/id="routed-([0-9a-f-]{36})"[^>]*data-table-version="(\d)"/, &1))
    |> Enum.sort_by(fn [_, _id, version] -> version end)
    |> Enum.map(fn [_, id, _version] -> id end)
  end
end
