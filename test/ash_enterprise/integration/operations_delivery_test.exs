defmodule AshEnterprise.Integration.OperationsDeliveryTest do
  @moduledoc """
  The webhook follow-up (`Delivery.follow_up`): a delivery is a nudge, so following it up only
  makes the reconcile of the activation that waits run sooner. It reads the registry by the
  delivery's id, learns the tenant from the registry's own answer, and decides nothing.
  """

  # async: false. It swaps the transport's application env, which is node-global.
  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]
  import AshEnterprise.Test.RegistryActivation

  alias AshEnterprise.Credentialing.{DemoData, RegistryApi}
  alias AshEnterprise.Credentialing.RegistryApi.Transport
  alias AshEnterprise.Execution.Invocation.ReconcileWorker
  alias AshEnterprise.Integration
  alias AshEnterprise.Platform.SystemActor

  @moduletag evidence: true

  setup do
    previous = Application.get_env(:ash_enterprise, Transport)
    on_exit(fn -> AshEnterprise.Test.RegistryActivation.restore_env(Transport, previous) end)

    admin = tenant!()
    clinic = DemoData.populate(admin.tenant)
    Oban.drain_queue(queue: :execution)

    # Two activations whose answers were lost: both `outcome_unknown`.
    [first, second | _] = clinic.credentials
    log = lossy_registry!()

    unknown =
      for credential <- [first, second],
          do: {credential, ready!(clinic, credential, admin.tenant)}

    Oban.drain_queue(queue: :execution)

    # The jobs the unknown outcomes enqueued themselves are gone, so what follows is the
    # nudge's own doing.
    AshEnterprise.Repo.delete_all(Oban.Job)

    %{tenant: admin.tenant, unknown: unknown, log: log}
  end

  defp deliver!(subject_id) do
    Integration.receive_provider_delivery!(
      %{
        provider: "credential-registry",
        dedup_key: "d-#{System.unique_integer([:positive])}",
        subject_id: subject_id
      },
      actor: SystemActor.oban()
    )
  end

  defp follow_up!(delivery) do
    delivery
    |> Ash.Changeset.for_update(:mark_followed_up, %{}, actor: SystemActor.oban())
    |> Ash.update!()
  end

  # A registry that knows one activation, for the credential the reference names.
  defp registry_knows!(reference) do
    Req.Test.stub(Transport, fn %{method: "GET"} = conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "id" => "act-77",
          "subjectReference" => reference,
          "status" => "active"
        })
      )
    end)

    point_transport!()
  end

  test "following up a delivery enqueues the reconcile of the waiting activation and nothing else",
       %{tenant: tenant, unknown: [{credential, row}, {_other, other_row}]} do
    registry_knows!(RegistryApi.reference(tenant, credential.id))

    followed = "act-77" |> deliver!() |> follow_up!()
    assert followed.state == :followed_up

    assert_enqueued(worker: ReconcileWorker, args: %{"primary_key" => %{"id" => row.id}})
    refute_enqueued(worker: ReconcileWorker, args: %{"primary_key" => %{"id" => other_row.id}})
  end

  test "an unknown outcome already handed to a person is not reconciled by the nudge",
       %{tenant: tenant, unknown: [{credential, row}, {_other, _other_row}]} do
    row
    |> Ash.reload!(actor: SystemActor.oban(), tenant: tenant)
    |> Ash.update!(%{},
      action: :request_resolution,
      actor: SystemActor.oban(),
      tenant: tenant
    )

    registry_knows!(RegistryApi.reference(tenant, credential.id))

    assert "act-77" |> deliver!() |> follow_up!() |> Map.fetch!(:state) == :ignored
    refute_enqueued(worker: ReconcileWorker)
  end

  test "a delivery for an activation with nothing waiting is ignored", %{tenant: tenant} do
    # The registry names a credential nobody is waiting on, and a tenant that is not ours.
    for reference <- [
          RegistryApi.reference(tenant, Ash.UUID.generate()),
          RegistryApi.reference(Ash.UUID.generate(), Ash.UUID.generate()),
          "not-a-reference"
        ] do
      registry_knows!(reference)
      assert "act-77" |> deliver!() |> follow_up!() |> Map.fetch!(:state) == :ignored
    end

    refute_enqueued(worker: ReconcileWorker)
  end

  test "an activation the registry does not know is ignored, a failing registry is retried",
       %{} do
    Req.Test.stub(Transport, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(404, ~s({"code": "not_found", "requestId": "r-1"}))
    end)

    point_transport!()
    assert "act-gone" |> deliver!() |> follow_up!() |> Map.fetch!(:state) == :ignored

    Req.Test.stub(Transport, fn conn ->
      Plug.Conn.send_resp(conn, 401, ~s({"code": "unauthorized"}))
    end)

    delivery = deliver!("act-1")

    assert {:error, _} =
             delivery
             |> Ash.Changeset.for_update(:mark_followed_up, %{}, actor: SystemActor.oban())
             |> Ash.update()

    assert Ash.reload!(delivery, authorize?: false).state == :received
  end
end
