defmodule AshEnterpriseWeb.ShowcaseCredentialingLiveTest do
  @moduledoc """
  Showcase slice 1 through the real LiveViews, in recorded mode: the credentialing tour
  (`/app/showcase/credentialing`) drives its beats over the seeded clinic. The coordinator
  asks from the tour; a committee member approves on the approvals surface; the decision
  is applied and the activation run the way their jobs do it (`apply_decision` as the
  `oban` system actor, then the `:execution` queue drained); the tour then shows the
  governed outcome of each beat. The fault panel exists only behind its demo flag.

  The kill beat (F2) needs a worker that really dies and a lease that really runs out,
  so it is the durability tier's
  (`AshEnterpriseWeb.ShowcaseCredentialingDurabilityTest`).
  """

  use AshEnterpriseWeb.ConnCase, async: false

  # The clinic's demo data ingests its licence documents into the evidence store.
  @moduletag evidence: true
  use Oban.Testing, repo: AshEnterprise.Repo

  import Phoenix.LiveViewTest
  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]

  alias AshEnterprise.Credentialing.{Credential, DemoData, Registry}
  alias AshEnterprise.Execution
  alias AshEnterprise.Faults
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Showcase
  alias AshEnterprise.Showcase.Credentialing, as: Tour

  @tour "/app/showcase/credentialing"

  setup do
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

  # The request the coordinator's latest click made for `credential`.
  defp request_for!(credential, %{clinic: clinic, tenant: tenant}) do
    clinic.coordinator
    |> actor(tenant)
    |> Tour.activations()
    |> Enum.find(&(&1.credential_id == credential.id))
  end

  defp ask!(view, credential, ctx) do
    view |> element("#raise-#{credential.id}") |> render_click()
    assert %{invocation: %{status: :awaiting_approval}} = request = request_for!(credential, ctx)
    request
  end

  # A committee member approves on the approvals surface, through its own button.
  defp approve!(request, %{clinic: clinic}) do
    {:ok, view, _html} = live(sign_in(hd(clinic.committee)), "/app/approvals")
    assert_push_event(view, "a2ui:messages", %{messages: _}, 5_000)

    render_hook(view, "a2ui:action", %{
      "version" => "v1.0",
      "action" => %{
        "name" => "invoke",
        "surfaceId" => "approvals",
        "sourceComponentId" => "data_grid",
        "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
        "context" => %{"action" => "approve", "recordId" => request.task_id}
      }
    })
  end

  # What the `:apply_decision` job and then the `:execute` job do.
  defp apply_and_run!(request, %{tenant: tenant}) do
    Execution.apply_invocation_decision!(request.invocation,
      actor: SystemActor.oban(),
      tenant: tenant
    )

    Oban.drain_queue(queue: :execution)
    Execution.get_invocation!(request.invocation.id, actor: SystemActor.oban(), tenant: tenant)
  end

  defp refreshed(view) do
    send(view.pid, :refresh)
    render(view)
    view
  end

  # Whether the coordinator holds the coordinator role's write grant on credentials now.
  defp coordinates?(%{clinic: clinic, tenant: tenant}) do
    context = ActorContext.build(clinic.coordinator, tenant: tenant)
    Map.has_key?(context.grants, {inspect(Credential), :write})
  end

  defp credential(credential, tenant),
    do: Ash.get!(Credential, credential.id, authorize?: false, tenant: tenant)

  test "the launcher offers the credentialing workspace and its tour", %{clinic: clinic} do
    {:ok, view, _html} = live(sign_in(clinic.coordinator), "/app")

    assert has_element?(view, "#launch-group-credentialing")
    assert has_element?(view, "#launch-credentials")
    assert has_element?(view, "#launch-credentialing_tour")
  end

  test "the workspace's own button asks to activate, as the person clicking", ctx do
    [credential | _] = ctx.clinic.credentials
    {:ok, view, _html} = live(sign_in(ctx.clinic.coordinator), "/app/credentialing")
    assert_push_event(view, "a2ui:messages", %{messages: messages}, 5_000)
    assert JSON.encode!(messages) =~ credential.number

    render_hook(view, "a2ui:action", %{
      "version" => "v1.0",
      "action" => %{
        "name" => "invoke",
        "surfaceId" => "credentials",
        "sourceComponentId" => "data_grid",
        "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
        "context" => %{"action" => "request_activation", "recordId" => credential.id}
      }
    })

    assert %{invocation: invocation} = request_for!(credential, ctx)

    assert {invocation.status, invocation.owner_id} ==
             {:awaiting_approval, ctx.clinic.coordinator.id}
  end

  test "the seeded clinic arrives with cases in several states", %{clinic: clinic} do
    {:ok, view, _html} = live(sign_in(clinic.coordinator), @tour)

    assert has_element?(view, "#model-mode", "Model mode: recorded")

    for credential <- Enum.take(clinic.credentials, 3),
        do: assert(has_element?(view, "#raise-#{credential.id}"))

    [waiting, rejected] = clinic.requests
    assert has_element?(view, "#awaiting-#{waiting.id}")
    assert has_element?(view, "#all-#{rejected.id}[data-status=rejected]", "approval_rejected")
  end

  test "the tour's beats in recorded mode: ask, approve, a correction, a revoked grant", ctx do
    [first, second, third | _] = ctx.clinic.credentials
    {:ok, view, _html} = live(sign_in(ctx.clinic.coordinator), @tour)

    # 1. Ask: the request waits for the committee, bound to exactly this request.
    asked = ask!(view, first, ctx)
    view = refreshed(view)
    assert has_element?(view, "#awaiting-#{asked.invocation.id} [data-bound=true]")
    assert has_element?(view, "#awaiting-approve-#{asked.invocation.id}")
    assert Registry.activations(first.id) == 0

    # 2. A committee member approves it; it runs, once, as the coordinator.
    approve!(asked, ctx)
    assert %{status: :succeeded} = apply_and_run!(asked, ctx)

    assert %{status: :active, registry_reference: "stub-registry:" <> _} =
             credential(first, ctx.tenant)

    assert Registry.activations(first.id) == 1
    view = refreshed(view)
    assert has_element?(view, "#all-#{asked.invocation.id}[data-status=succeeded]")
    refute has_element?(view, "#raise-#{first.id}")

    # 3. (F4) The credential is corrected while the request waits: the approval is for
    # the credential as it was, so the request goes stale and nothing is activated.
    corrected = ask!(view, second, ctx)
    view = refreshed(view)
    view |> element("#fault-correct-#{corrected.invocation.id}") |> render_click()
    approve!(corrected, ctx)

    assert %{status: :stale, error_code: "subject_changed"} = apply_and_run!(corrected, ctx)
    assert credential(second, ctx.tenant).status == :pending
    assert Registry.activations(second.id) == 0
    view = refreshed(view)
    assert has_element?(view, "#stale-#{corrected.invocation.id}", "subject_changed")

    # 4. (F5) The coordinator's grant is revoked before the activation runs: it runs as
    # the coordinator rebuilt from their grants now, and is denied; the registry is
    # never asked.
    revoked = ask!(view, third, ctx)
    view |> element("#fault-revoke") |> render_click()
    approve!(revoked, ctx)

    assert %{status: :failed, failure_class: :denied} = apply_and_run!(revoked, ctx)
    assert credential(third, ctx.tenant).status == :pending
    assert Registry.activations(third.id) == 0
    view = refreshed(view)
    assert has_element?(view, "#denied-#{revoked.invocation.id}", "denied")

    # Restoring the clinic gives the coordinator their role back.
    refute coordinates?(ctx)
    view |> element("#fault-restore") |> render_click()
    assert coordinates?(ctx)
  end

  test "the kill control arms the fault point between the registry and the record", ctx do
    on_exit(&Faults.disarm_all/0)
    {:ok, view, _html} = live(sign_in(ctx.clinic.coordinator), @tour)
    view |> element("#fault-kill") |> render_click()

    {pid, ref} = spawn_monitor(fn -> Faults.point(Tour.kill_point()) end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
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

    test "the fault panel is absent, and its controls refuse", ctx do
      refute Showcase.fault_controls?()
      {:ok, view, _html} = live(sign_in(ctx.clinic.coordinator), @tour)

      refute has_element?(view, "#fault-panel")
      refute has_element?(view, "#fault-kill")
      assert has_element?(view, "#beat-raise")

      assert render_hook(view, "fault", %{"control" => "kill"}) =~ "The fault panel is off here."

      assert render_hook(view, "fault", %{"control" => "revoke"}) =~
               "The fault panel is off here."

      {pid, ref} = spawn_monitor(fn -> Faults.point(Tour.kill_point()) end)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      assert coordinates?(ctx)
    end
  end

  test "production's configuration leaves the demo flag off" do
    config = Config.Reader.read!("config/config.exs", env: :prod, target: :host)
    assert get_in(config, [:ash_enterprise, Showcase, :fault_controls?]) == false
    assert get_in(config, [:ash_enterprise, Showcase, :model_mode]) == :recorded
  end

  test "the tour speaks French", %{clinic: clinic} do
    {:ok, view, _html} = live(sign_in(clinic.coordinator), @tour <> "?locale=fr")

    assert has_element?(view, "#beat-raise h2", "Demander l")
    assert has_element?(view, "#model-mode", "Mode du modèle : enregistré")
    assert has_element?(view, "#fault-panel h2", "Panneau de pannes")
    assert has_element?(view, "#page-header h1", "Visite de l")

    {:ok, view, _html} = live(sign_in(clinic.coordinator), @tour)
    assert has_element?(view, "#beat-raise h2", "Ask to activate a credential")
  end
end
