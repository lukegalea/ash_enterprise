defmodule AshEnterpriseWeb.RecoveryLiveTest do
  @moduledoc """
  The recovery surface (`/app/recovery`) over the seeded clinic, the LiveView twin of
  `assets/e2e/recovery.spec.ts`. The uncertain outcome comes from the showcase's fault
  panel (its "lose the registry's answer" control), never from seeded history: the
  coordinator asks to activate a credential, a committee member approves, the registry
  accepts and the answer is lost, and the registry cannot say afterwards whether it
  took it, so the request waits for a person.

  The administrator then sees it as uncertain, with the choices of what happened and
  no Retry; settles it as not done; simulates a rerun (nothing is created); reruns it
  (a new request with a new key, linked to the first); cancels the rerun (the page says
  completed effects are not reversed); and finds each act listed with who did it and why.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  # The clinic's demo data ingests its licence documents into the evidence store, and
  # seeding it takes most of a minute.
  @moduletag evidence: true
  @moduletag timeout: 240_000
  use Oban.Testing, repo: AshEnterprise.Repo

  import Phoenix.LiveViewTest
  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]

  alias AshEnterprise.Credentialing.DemoData
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Intervention
  alias AshEnterprise.Faults
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Showcase.Credentialing, as: Tour

  setup do
    on_exit(&Faults.disarm_all/0)
    admin = tenant!()
    %{admin: admin, tenant: admin.tenant, clinic: DemoData.populate(admin.tenant)}
  end

  defp sign_in(user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp oban(ctx), do: [actor: SystemActor.oban(), tenant: ctx.tenant]

  defp actor(user, tenant),
    do: ActorContext.attach(user, ActorContext.build(user, tenant: tenant))

  defp drain, do: Oban.drain_queue(queue: :execution, with_recursion: true)

  defp invocations(ctx), do: Execution.list_invocations!(oban(ctx))

  defp interventions(ctx),
    do: Ash.read!(Intervention, authorize?: false, tenant: ctx.tenant)

  # The fault panel's control, the coordinator's ask, a committee member's approval on
  # the approvals surface, and the jobs that follow: the request is left uncertain.
  defp uncertain!(%{clinic: clinic} = ctx) do
    [credential | _] = clinic.credentials

    {:ok, tour, _html} = live(sign_in(clinic.coordinator), "/app/showcase/credentialing")
    tour |> element("#fault-lose") |> render_click()
    tour |> element("#raise-#{credential.id}") |> render_click()

    request =
      clinic.coordinator
      |> actor(ctx.tenant)
      |> Tour.activations()
      |> Enum.find(&(&1.credential_id == credential.id))

    {:ok, approvals, _html} = live(sign_in(hd(clinic.committee)), "/app/approvals")
    assert_push_event(approvals, "a2ui:messages", %{messages: _}, 5_000)

    render_hook(approvals, "a2ui:action", %{
      "version" => "v1.0",
      "action" => %{
        "name" => "invoke",
        "surfaceId" => "approvals",
        "sourceComponentId" => "data_grid",
        "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
        "context" => %{"action" => "approve", "recordId" => request.task_id}
      }
    })

    Execution.apply_invocation_decision!(request.invocation, oban(ctx))
    drain()

    row = Execution.get_invocation!(request.invocation.id, oban(ctx))
    assert {row.status, is_nil(row.resolution_requested_at)} == {:outcome_unknown, false}
    row
  end

  test "an uncertain outcome is settled, simulated, rerun and cancelled, each act recorded",
       ctx do
    row = uncertain!(ctx)
    admin = sign_in(ctx.admin.user)

    {:ok, index, _html} = live(admin, "/app/recovery")
    assert has_element?(index, "#uncertain-rows-#{row.id}[data-status=uncertain]")

    {:ok, view, _html} = live(admin, "/app/recovery/#{row.id}")

    # Uncertain, the choices of what happened, and no Retry and no Rerun.
    assert has_element?(view, "#status[data-status=uncertain]")
    assert has_element?(view, "#settle-form")
    assert has_element?(view, "#settle-succeeded")
    assert has_element?(view, "#settle-failed")
    assert has_element?(view, "#settle-retry")
    refute has_element?(view, "button", ~r/\bretry\b/i)
    refute has_element?(view, "#rerun-form")
    refute has_element?(view, "#cancel-form")

    # Settled as not done, with a reason; applied by the job it enqueued.
    view
    |> form("#settle-form", %{
      "resolution" => "failed",
      "reason" => "The registry has no record of it."
    })
    |> render_submit()

    drain()
    assert Execution.get_invocation!(row.id, oban(ctx)).status == :failed
    render(view)
    assert has_element?(view, "#status[data-status=failed]")

    # Rerun says what will run again before anyone asks.
    assert has_element?(view, "#rerun-statement", "calls outside the application again")
    assert has_element?(view, "#rerun-statement", "new key")
    assert has_element?(view, "#rerun-statement", "waits for approval again")

    # Simulate creates nothing.
    before = invocations(ctx)
    view |> element("#simulate") |> render_click()
    assert has_element?(view, "#simulation", "Nothing was created")
    assert has_element?(view, "#simulation-arguments", "still valid")
    assert invocations(ctx) == before

    # Rerun: a new request with a new key and a link to the first.
    {:ok, rerun_view, _html} =
      view
      |> form("#rerun-form", %{"reason" => "Ask the registry again."})
      |> render_submit()
      |> follow_redirect(admin)

    [rerun] = Enum.reject(invocations(ctx), &(&1.id in Enum.map(before, fn r -> r.id end)))
    assert rerun.rerun_of_id == row.id
    assert rerun.invocation_key != row.invocation_key
    assert rerun.status == :awaiting_approval
    assert has_element?(rerun_view, "#rerun-of[href='/app/recovery/#{row.id}']")
    assert has_element?(rerun_view, "#status[data-status=waiting]")

    # Cancel says what it does not undo.
    assert has_element?(rerun_view, "#cancel-statement", "Completed effects are not reversed")

    rerun_view
    |> form("#cancel-form", %{"reason" => "Asked twice by mistake."})
    |> render_submit()

    assert Execution.get_invocation!(rerun.id, oban(ctx)).status == :cancelled
    assert has_element?(rerun_view, "#status[data-status=cancelled]")
    assert has_element?(rerun_view, "#interventions [data-act=cancel]", "Asked twice by mistake.")

    # Every act, with who and why.
    {:ok, view, _html} = live(admin, "/app/recovery/#{row.id}")
    email = to_string(ctx.admin.user.email)

    assert has_element?(
             view,
             "#interventions [data-act=resolve]",
             "The registry has no record of it."
           )

    assert has_element?(view, "#interventions [data-act=resolve] .intervention-actor", email)
    assert has_element?(view, "#interventions [data-act=rerun]", "Ask the registry again.")
    assert has_element?(view, "#rerun-#{rerun.id}")
  end

  test "someone not asked to settle is refused, and nothing is recorded", ctx do
    row = uncertain!(ctx)
    {:ok, view, _html} = live(sign_in(hd(ctx.clinic.committee)), "/app/recovery/#{row.id}")

    if has_element?(view, "#settle-form") do
      view
      |> form("#settle-form", %{"resolution" => "succeeded", "reason" => "Looks done."})
      |> render_submit()
    end

    assert interventions(ctx) == []
    drain()
    assert Execution.get_invocation!(row.id, oban(ctx)).status == :outcome_unknown
  end

  test "a settle without a choice is refused, and the outcome stays uncertain", ctx do
    row = uncertain!(ctx)
    {:ok, view, _html} = live(sign_in(ctx.admin.user), "/app/recovery/#{row.id}")

    view |> form("#settle-form", %{"reason" => "Not sure."}) |> render_submit()
    assert has_element?(view, "#flash-error", "Say what happened.")

    render_submit(view, "settle", %{"resolution" => "maybe", "reason" => "Not sure."})
    assert has_element?(view, "#flash-error", "Say what happened.")

    assert interventions(ctx) == []
    assert has_element?(view, "#status[data-status=uncertain]")
  end

  test "an invocation the person cannot read shows nothing to act on", ctx do
    row = uncertain!(ctx)
    stranger = tenant!()
    {:ok, view, _html} = live(sign_in(stranger.user), "/app/recovery/#{row.id}")

    refute has_element?(view, "#invocation-#{row.id}")
    refute has_element?(view, "#settle-form")
    refute has_element?(view, "#rerun-form")

    # An act sent anyway is refused, and nothing is written.
    render_submit(view, "settle", %{"resolution" => "succeeded", "reason" => "Done."})
    render_submit(view, "rerun", %{"reason" => "Again."})
    assert has_element?(view, "#flash-error", "nothing here to act on")
    assert interventions(ctx) == []
    assert Execution.get_invocation!(row.id, oban(ctx)).status == :outcome_unknown
  end
end
