defmodule AshEnterpriseWeb.ShowcaseLicenceReaderLiveTest do
  @moduledoc """
  Showcase slice 2 through the real LiveViews, in recorded mode: the credentialing tour's
  beats 6 to 9 (`/app/showcase/credentialing`) over the seeded clinic. The coordinator
  starts the licence reader from the tour; its steps and tool calls run as their jobs do
  (the `:agent_runs` and `:execution` queues drained by hand); the tour then shows each
  beat's outcome: findings citing their lines, also on the credential's own page; a model
  timeout resumed without looking again (F1); a budget exhausted with its typed reason
  and extended by the clinic director (F8); a clinician erased by the platform operator
  while the audit chain verifies (F11). No beat needs a model or a key.
  """

  use AshEnterpriseWeb.ConnCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  # The clinic's demo data ingests its licence documents into the evidence store.
  @moduletag evidence: true

  import Phoenix.LiveViewTest
  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]
  import Ecto.Query, only: [from: 2]

  alias AshEnterprise.Credentialing.DemoData
  alias AshEnterprise.Execution
  alias AshEnterprise.Faults
  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Showcase
  alias AshEnterprise.Showcase.Credentialing, as: Tour

  @tour "/app/showcase/credentialing"

  setup do
    admin = tenant!()
    %{admin: admin, tenant: admin.tenant, clinic: DemoData.populate(admin.tenant)}
  end

  defp sign_in(user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp credential(clinic, number), do: Enum.find(clinic.credentials, &(&1.number == number))

  # What the run's `:step` jobs and its tool calls' `:execute` jobs do, until neither
  # queue has anything left.
  defp drain!(rounds \\ 12)
  defp drain!(0), do: :ok

  defp drain!(rounds) do
    steps = Oban.drain_queue(queue: :agent_runs, with_recursion: true)
    calls = Oban.drain_queue(queue: :execution, with_recursion: true)

    if steps.success + steps.failure + calls.success + calls.failure > 0,
      do: drain!(rounds - 1),
      else: :ok
  end

  # The coordinator clicks a credential's read button; the jobs run.
  defp read!(view, credential, tenant) do
    view |> element("#read-#{credential.id}") |> render_click()
    drain!()

    [run] =
      Execution.list_agent_runs!(
        query: [filter: [subject_id: credential.clinician_id]],
        authorize?: false,
        tenant: tenant
      )

    run
  end

  defp row(id, run), do: "##{id}-#{run.id}"

  test "6: a reading records typed findings citing their lines, shown on the case", ctx do
    %{clinic: clinic, tenant: tenant} = ctx
    credential = credential(clinic, "DEMO-PT-0001")
    {:ok, view, _html} = live(sign_in(clinic.coordinator), @tour)

    assert has_element?(view, "#model-mode", "Model mode: recorded")
    run = read!(view, credential, tenant)
    send(view.pid, :refresh)

    assert has_element?(view, row("read", run) <> "[data-status=completed]")
    assert has_element?(view, row("read", run) <> " [data-findings=\"2\"]")

    assert has_element?(
             view,
             row("read", run) <> " [data-question=licence_number][data-status=found]",
             "DEMO-PT-0001"
           )

    assert has_element?(
             view,
             row("read", run) <> " [data-question=licence_valid_until]",
             "2028-06-30"
           )

    assert has_element?(view, row("read", run) <> " [data-lookups=\"2\"][data-attempts=\"1,1\"]")

    # On the case: the credential's own page says what was found, and where.
    # (`/app/r/credentials/:id` redirects to the workspace with the credential selected.)
    {:ok, detail, _html} =
      live(
        sign_in(clinic.coordinator),
        "/app/credentialing?ctx[credential]=#{credential.id}"
      )

    assert_push_event(detail, "a2ui:messages", %{messages: messages}, 5_000)
    encoded = JSON.encode!(messages)
    assert encoded =~ "Found in its documents"
    assert encoded =~ "Licence number: DEMO-PT-0001"
    assert encoded =~ "line 5"
  end

  test "7 (F1): the model times out after the lookups; the run resumes and looks nothing up again",
       ctx do
    %{clinic: clinic, tenant: tenant} = ctx
    on_exit(&Faults.disarm_all/0)
    credential = credential(clinic, "DEMO-RN-0002")
    {:ok, view, _html} = live(sign_in(clinic.coordinator), @tour)

    view |> element("#fault-timeout") |> render_click()
    run = read!(view, credential, tenant)
    send(view.pid, :refresh)

    assert has_element?(view, row("timed-out", run) <> "[data-status=running]")
    assert has_element?(view, row("timed-out", run) <> " [data-model-calls=\"ok,error\"]")
    assert has_element?(view, row("timed-out", run) <> " [data-attempts=\"1,1\"]")

    # The lease runs out, and the recover sweep queues the run again.
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    {1, _} =
      AshEnterprise.Repo.update_all(
        from(r in "exec_agent_runs", where: r.id == type(^run.id, Ecto.UUID)),
        set: [lease_expires_at: past]
      )

    run = Execution.get_agent_run!(run.id, authorize?: false, tenant: tenant)
    {:ok, _} = Execution.recover_agent_run(run, actor: SystemActor.oban(), tenant: tenant)
    drain!()
    send(view.pid, :refresh)

    assert has_element?(view, row("timed-out", run) <> "[data-status=completed]")
    assert has_element?(view, row("timed-out", run) <> " [data-model-calls=\"ok,error,ok,ok\"]")

    assert has_element?(
             view,
             row("timed-out", run) <> " [data-lookups=\"2\"][data-attempts=\"1,1\"]"
           )

    assert has_element?(view, row("timed-out", run) <> " [data-findings=\"2\"]")
  end

  test "8 (F8): a long bundle runs out of budget with its reason; the director extends it",
       ctx do
    %{clinic: clinic, tenant: tenant} = ctx
    credential = credential(clinic, "DEMO-OT-0003")
    {:ok, view, _html} = live(sign_in(clinic.coordinator), @tour)

    run = read!(view, credential, tenant)
    send(view.pid, :refresh)

    assert has_element?(view, row("budget", run) <> "[data-status=waiting]")
    assert has_element?(view, row("budget", run) <> " [data-blocked-on=budget]", "token_budget")

    # The coordinator may not extend it; the clinic director may.
    assert view |> element("#extend-#{run.id}") |> render_click() =~
             "Not allowed for the person signed in."

    {:ok, director, _html} = live(sign_in(clinic.director), @tour)
    director |> element("#extend-#{run.id}") |> render_click()
    drain!()
    send(director.pid, :refresh)

    assert has_element?(director, row("budget", run) <> "[data-status=completed]")

    assert has_element?(
             director,
             row("budget", run) <> " [data-question=licence_valid_until][data-status=ambiguous]",
             "lines 6, 7"
           )
  end

  test "9 (F11): the operator erases the clinician; the run reads as erased and the chain verifies",
       ctx do
    %{admin: admin, clinic: clinic, tenant: tenant} = ctx
    credential = credential(clinic, "DEMO-SLT-0004")
    {:ok, view, _html} = live(sign_in(clinic.coordinator), @tour)

    run = read!(view, credential, tenant)
    send(view.pid, :refresh)
    assert has_element?(view, "#erase-#{credential.id}")

    # Only the platform operator may shred.
    assert view |> element("#erase-#{credential.id}") |> render_click() =~
             "Not allowed for the person signed in."

    Seeder.grant_platform_operator(admin.user)
    {:ok, operator, _html} = live(sign_in(admin.user), @tour)
    operator |> element("#erase-#{credential.id}") |> render_click()

    assert has_element?(operator, "#chain-verifies")
    assert has_element?(operator, row("erased", run) <> "[data-erased=true]")
    assert has_element?(operator, row("erased", run) <> " [data-steps]", "erased")
    refute has_element?(operator, "#erase-#{credential.id}")
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

    test "the timeout control is absent and refuses; the reading beats stay", ctx do
      {:ok, view, _html} = live(sign_in(ctx.clinic.coordinator), @tour)

      refute has_element?(view, "#fault-timeout")
      assert has_element?(view, "#beat-read")

      assert render_hook(view, "fault", %{"control" => "timeout"}) =~
               "The fault panel is off here."

      assert Faults.point(Tour.timeout_point()) == :ok
    end
  end

  test "the reading beats speak French", %{clinic: clinic} do
    {:ok, view, _html} = live(sign_in(clinic.coordinator), @tour <> "?locale=fr")

    assert has_element?(view, "#beat-read h2", "Lire les documents")
    assert has_element?(view, "#beat-erase h2", "demande à être effacé")
    assert has_element?(view, "#fault-timeout", "Faire expirer le modèle")
  end
end
