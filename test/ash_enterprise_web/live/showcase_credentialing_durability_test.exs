defmodule AshEnterpriseWeb.ShowcaseCredentialingDurabilityTest do
  @moduledoc """
  Showcase slice 1's kill beat (F2) through the real LiveViews, on the durability tier:
  the tour's fault panel arms the kill, the coordinator asks from the tour, a committee
  member approves on the approvals surface, and a real `:execute` job dies after the
  registry accepted the activation and before anything was recorded.

  The worker held the lease, so nothing runs the request again. When the lease runs out
  (moved on here, as the clock would), the reconcile sweep makes the request
  `outcome_unknown`, asks the registry through the target's `reconcile_with`
  (`lookup_activation`) and settles it `succeeded` with the registry's reference. The
  registry took the activation once, and the tour shows it.
  """

  use AshEnterprise.DurabilityCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import AshEnterprise.Test.Execution.Durable

  alias AshEnterprise.Credentialing.{Credential, DemoData, Registry}
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Invocation.{ReconcileScheduler, ReconcileWorker}
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Showcase.Credentialing, as: Tour

  @endpoint AshEnterpriseWeb.Endpoint
  @tour "/app/showcase/credentialing"

  setup do
    subscribe_jobs()
    %{tenant: tenant} = clinic!()
    %{tenant: tenant, clinic: DemoData.populate(tenant)}
  end

  defp sign_in(user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp refreshed(view) do
    send(view.pid, :refresh)
    render(view)
    view
  end

  test "the worker dies after the registry accepted: unknown, reconciled, not repeated", %{
    tenant: tenant,
    clinic: clinic
  } do
    [credential | _] = clinic.credentials
    {:ok, view, _html} = live(sign_in(clinic.coordinator), @tour)

    view |> element("#fault-kill") |> render_click()
    view |> element("#raise-#{credential.id}") |> render_click()

    coordinator =
      ActorContext.attach(
        clinic.coordinator,
        ActorContext.build(clinic.coordinator, tenant: tenant)
      )

    request = Enum.find(Tour.activations(coordinator), &(&1.credential_id == credential.id))
    assert request.invocation.status == :awaiting_approval

    # A committee member approves on the approvals surface.
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

    # Applied as the `:apply_decision` job applies it; the `:execute` job it enqueues
    # runs for real and is killed between the registry and the record.
    row = Execution.apply_invocation_decision!(request.invocation, oban(tenant))
    assert row.status == :ready
    [job] = jobs(row.id)
    assert %{kind: :exit} = await_job(job.id, :failure)

    held = committed(row.id, tenant)
    assert {held.status, held.lease_epoch} == {:executing, 1}
    assert Registry.activations(credential.id) == 1

    view = refreshed(view)
    assert has_element?(view, "#reconciled-#{row.id}[data-status=executing]")

    # The lease runs out; the reconcile sweep settles the row by asking the registry.
    elapse!(row, :lease_expires_at)
    sweep = Oban.insert!(ReconcileScheduler.new(%{}))
    await_job(sweep.id, :success)
    [reconcile | _] = jobs(row.id, ReconcileWorker)
    await_job(reconcile.id, :success)

    {:ok, %{reference: reference}} = Registry.lookup(credential.id)
    done = committed(row.id, tenant)

    assert {done.status, done.reconciled_via, done.effect_system, done.effect_ref} ==
             {:succeeded, "reconcile_with", "credential-registry", reference}

    assert Registry.activations(credential.id) == 1

    # Reconciliation records the outcome on the request; the credential's own row was
    # never written by the worker that died.
    assert Ash.get!(Credential, credential.id, authorize?: false, tenant: tenant).status ==
             :pending

    view = refreshed(view)
    assert has_element?(view, "#reconciled-#{row.id}[data-status=succeeded]", "reconcile_with")
    assert has_element?(view, "#reconciled-#{row.id} [data-registry-activations=\"1\"]")
  end
end
