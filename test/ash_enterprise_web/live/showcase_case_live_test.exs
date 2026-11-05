defmodule AshEnterpriseWeb.ShowcaseCaseLiveTest do
  @moduledoc """
  Showcase slice 3 through the real LiveView, in recorded mode: the credentialing tour's
  case beats (`/app/showcase/credentialing`, beats 10 to 15). The coordinator opens a
  credential's case from the tour; the evidence checks run side by side and one is refused
  (F7); the filing system's webhook is delivered twice and before the case waits (F6); the
  committee decides; the approved case shows its re-credentialing timer.

  With the demo flag off, every beat that needs a fault control says so in place.
  The process below the page is `AshEnterprise.Showcase.CredentialingCaseTest`'s; the
  approval over ACP surviving a restart is
  `AshEnterprise.Acp.CaseApprovalDurableTest`'s.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  # The clinic's demo data ingests its licence documents into the evidence store.
  @moduletag evidence: true

  import Phoenix.LiveViewTest
  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Triggers.SweepWorker
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Credentialing.DemoData
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Showcase
  alias AshEnterprise.Showcase.Case, as: CaseTour

  @tour "/app/showcase/credentialing"
  @fault_beats ~w(beat-stale beat-revoked beat-reconciled beat-timeout beat-webhook)

  setup do
    TestJobs.clear()
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

  defp sweep!(tenant), do: SweepWorker.perform(%Oban.Job{args: %{"tenant" => tenant}})

  defp the_case(ctx, credential),
    do:
      ctx.clinic.coordinator
      |> actor(ctx.tenant)
      |> CaseTour.cases()
      |> Enum.find(&(&1.credential.id == credential.id))

  test "the beats in recorded mode: a refused check (F7), a repeated webhook (F6), the committee, the timer",
       ctx do
    refused = ctx.clinic.case_credential
    [clean | _] = ctx.clinic.credentials
    {:ok, view, _html} = live(sign_in(ctx.clinic.coordinator), @tour)

    assert has_element?(view, "#model-mode", "Model mode: recorded")

    # 10, 11. The case with no document: one check refused, the other passed, the
    # document asked for once, and the case waits for it.
    view |> element("#open-case-#{refused.id}") |> render_click()
    view = refreshed(view)
    kase = the_case(ctx, refused)

    assert has_element?(view, "#refused-#{kase.instance.id}[data-status=running]")

    assert has_element?(
             view,
             "#refused-#{kase.instance.id} [data-check-status=failed]",
             "licence_document_missing"
           )

    assert has_element?(view, "#refused-#{kase.instance.id} [data-check-status=succeeded]")
    assert has_element?(view, "#refused-#{kase.instance.id} [data-requests='1']")

    assert has_element?(
             view,
             "#refused-#{kase.instance.id} [data-waiting-for=AwaitDocument]"
           )

    # 12. The webhook arrives twice: two deliveries, one recorded, one continuation.
    view |> element("#fault-webhook-twice-#{refused.id}") |> render_click()
    sweep!(ctx.tenant)
    sweep!(ctx.tenant)
    view = refreshed(view)

    assert has_element?(
             view,
             "#webhooks-#{kase.instance.id}[data-deliveries='1'][data-continuations='1']"
           )

    # 13. The committee's task is open; the coordinator may not decide it, a member may.
    assert %{review: %{status: :open, id: task_id}} = the_case(ctx, refused)
    assert has_element?(view, "#reviews-#{kase.instance.id} [data-review-status=open]")

    coordinator = actor(ctx.clinic.coordinator, ctx.tenant)
    assert {:error, _} = decide(task_id, coordinator, ctx.tenant)
    assert {:ok, _} = decide(task_id, actor(hd(ctx.clinic.committee), ctx.tenant), ctx.tenant)

    # 14. The approved case shows when it is due for re-credentialing.
    view = refreshed(view)
    assert has_element?(view, "#timers-#{kase.instance.id} [data-due]", "Re-credentialing due")

    # A credential whose documents are filed passes both checks and goes straight to the
    # committee.
    view |> element("#open-case-#{clean.id}") |> render_click()
    view = refreshed(view)
    clean_case = the_case(ctx, clean)
    assert has_element?(view, "#reviews-#{clean_case.instance.id} [data-review-status=open]")
    refute has_element?(view, "#refused-#{clean_case.instance.id}")
  end

  test "a webhook delivered before the case waits for it is found when it does (F6, out of order)",
       ctx do
    credential = ctx.clinic.case_credential
    {:ok, view, _html} = live(sign_in(ctx.clinic.coordinator), @tour)

    view |> element("#fault-webhook-early-#{credential.id}") |> render_click()
    view |> element("#open-case-#{credential.id}") |> render_click()
    sweep!(ctx.tenant)
    view = refreshed(view)

    kase = the_case(ctx, credential)
    assert kase.continuations == 1
    assert has_element?(view, "#webhooks-#{kase.instance.id}[data-continuations='1']")
    assert has_element?(view, "#reviews-#{kase.instance.id} [data-review-status=open]")
  end

  test "a person who may not change a credential is refused when opening its case", ctx do
    credential = ctx.clinic.case_credential
    {:ok, view, _html} = live(sign_in(hd(ctx.clinic.committee)), @tour)

    # The committee reads the clinic but does not coordinate it.
    html = render_hook(view, "open_case", %{"id" => credential.id})
    assert html =~ "Not allowed for the person signed in."
  end

  test "the tour speaks French over the case beats", ctx do
    {:ok, view, _html} = live(sign_in(ctx.clinic.coordinator), @tour <> "?locale=fr")

    assert has_element?(view, "#beat-case h2", "Ouvrir le dossier")
    assert has_element?(view, "#beat-checks h2", "(F7)")

    {:ok, view, _html} = live(sign_in(ctx.clinic.coordinator), @tour)
    assert has_element?(view, "#beat-case h2", "Open a credential's case")
  end

  describe "with the demo flag on" do
    test "no beat says it needs the demo build", ctx do
      assert Showcase.fault_controls?()
      {:ok, view, _html} = live(sign_in(ctx.clinic.coordinator), @tour)

      for beat <- @fault_beats, do: refute(has_element?(view, "##{beat} .demo-build-note"))
    end
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
      {:ok, view, _html} = live(sign_in(ctx.clinic.coordinator), @tour)

      for beat <- @fault_beats do
        assert has_element?(view, "##{beat} .demo-build-note", "demo build only"),
               "#{beat} does not say it needs the demo build"
      end

      # The beats that need no control do not claim to.
      for beat <- ~w(beat-raise beat-approve beat-case beat-checks beat-committee beat-timer) do
        refute has_element?(view, "##{beat} .demo-build-note")
      end

      refute has_element?(view, "#fault-panel")
      refute has_element?(view, "[id^=fault-webhook]")

      # The tour still reads cleanly: the case beats are there, and the webhook control
      # refuses if it is sent anyway.
      assert has_element?(view, "#beat-webhook h2")
      assert has_element?(view, "#beat-case h2")

      assert render_hook(view, "fault", %{
               "control" => "webhook",
               "id" => ctx.clinic.case_credential.id
             }) =~ "The fault panel is off here."
    end

    test "the demo build note reads in French", ctx do
      {:ok, view, _html} = live(sign_in(ctx.clinic.coordinator), @tour <> "?locale=fr")
      assert has_element?(view, "#beat-webhook .demo-build-note", "version de démonstration")
    end
  end

  defp decide(task_id, actor, tenant) do
    HumanTask
    |> Ash.ActionInput.for_action(:approve, %{record_id: task_id}, actor: actor, tenant: tenant)
    |> Ash.run_action()
  end
end
