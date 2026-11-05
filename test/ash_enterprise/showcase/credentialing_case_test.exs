defmodule AshEnterprise.Showcase.CredentialingCaseTest do
  @moduledoc """
  Showcase slice 3 below the tour: the credentialing case as a BPMN process
  (`AshEnterprise.Credentialing.CaseProcess`) on the seeded clinic.

    * the evidence checks run side by side, and one the business refuses is handled by its
      boundary without losing the other (F7);
    * the "document received" webhook delivered twice, and before the case waits for it,
      moves the case on once (F6);
    * the committee decides on a task the person who owns the credential may not decide, and
      an approved case waits for its re-credentialing date, which the case shows.

  The engine's jobs run inline, as in every test; the timer is fired by hand. SYNTHETIC data
  only.
  """

  use AshEnterprise.DataCase, async: false

  # The clinic's demo data ingests its licence documents into the evidence store.
  @moduletag evidence: true

  require Ash.Query

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Triggers.SweepWorker
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.{CaseProcess, DemoData, DocumentEvent, DocumentWebhook}
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Showcase.Case, as: Tour

  setup do
    TestJobs.clear()
    admin = tenant!()
    clinic = DemoData.populate(admin.tenant)
    coordinator = actor(clinic.coordinator, admin.tenant)
    %{tenant: admin.tenant, clinic: clinic, coordinator: coordinator}
  end

  defp actor(user, tenant),
    do: ActorContext.attach(user, ActorContext.build(user, tenant: tenant))

  defp open!(credential, actor, tenant) do
    Credentialing.open_case!(credential.id, actor: actor, tenant: tenant)
  end

  defp the_case(actor, credential) do
    Enum.find(Tour.cases(actor), &(&1.credential.id == credential.id))
  end

  defp sweep!(tenant), do: SweepWorker.perform(%Oban.Job{args: %{"tenant" => tenant}})

  defp events(tenant, type) do
    DocumentEvent
    |> Ash.Query.filter(type == ^type)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  test "a refused check takes its boundary while the other completes, and the case waits for the document (F7)",
       %{tenant: tenant, clinic: clinic, coordinator: coordinator} do
    credential = clinic.case_credential

    assert %{"status" => "running"} = open!(credential, coordinator, tenant)
    kase = the_case(coordinator, credential)

    # Side by side: the documents check was refused by the business, the expiry check passed.
    by_target = Map.new(kase.checks, &{&1.target, &1})

    assert %{status: :failed, error_code: "licence_document_missing"} =
             by_target["AshEnterprise.Credentialing.Credential.check_documents"]

    assert %{status: :succeeded} =
             by_target["AshEnterprise.Credentialing.Credential.check_expiry"]

    # The boundary asked for the document once, and the case waits for it.
    assert [%{type: "document.requested"}] = kase.requests
    assert CaseProcess.await_node() in kase.waiting_for
    assert kase.review == nil
    assert kase.continuations == 0
  end

  test "a webhook delivered twice moves the case on once (F6)",
       %{tenant: tenant, clinic: clinic, coordinator: coordinator} do
    credential = clinic.case_credential
    open!(credential, coordinator, tenant)

    delivery = "delivery-#{System.unique_integer([:positive])}"

    assert DocumentWebhook.deliver(tenant, credential.id, delivery) == :received
    assert DocumentWebhook.deliver(tenant, credential.id, delivery) == :duplicate
    assert [_one] = events(tenant, "document.received")

    sweep!(tenant)
    sweep!(tenant)

    kase = the_case(coordinator, credential)
    assert length(kase.deliveries) == 1
    assert kase.continuations == 1
    assert kase.review.status == :open
    refute CaseProcess.await_node() in kase.waiting_for
  end

  test "a webhook that arrives before the case waits for it is found when it does (F6)",
       %{tenant: tenant, clinic: clinic, coordinator: coordinator} do
    credential = clinic.case_credential

    # Out of order: the document is there before anyone asked.
    assert DocumentWebhook.deliver(tenant, credential.id, "early-delivery") == :received
    open!(credential, coordinator, tenant)
    sweep!(tenant)

    kase = the_case(coordinator, credential)
    assert kase.continuations == 1
    assert kase.review.status == :open

    # And the sender repeating itself afterwards wakes nothing.
    assert DocumentWebhook.deliver(tenant, credential.id, "early-delivery") == :duplicate
    sweep!(tenant)
    assert the_case(coordinator, credential).continuations == 1
  end

  test "the committee decides, and the approved case shows its re-credentialing timer",
       %{tenant: tenant, clinic: clinic, coordinator: coordinator} do
    [credential | _] = clinic.credentials
    open!(credential, coordinator, tenant)

    # Both checks passed straight away: the committee's task is open.
    kase = the_case(coordinator, credential)
    assert Enum.all?(kase.checks, &(&1.status == :succeeded))
    assert %{status: :open, id: task_id} = kase.review
    assert kase.timer == nil

    # The coordinator owns the credential and may not decide on it; a committee member may.
    assert {:error, _} = decide(task_id, coordinator, tenant)
    member = actor(hd(clinic.committee), tenant)
    assert {:ok, _} = decide(task_id, member, tenant)

    kase = the_case(coordinator, credential)
    assert kase.review.status == :completed
    assert %{due_at: due} = kase.timer
    assert_in_delta DateTime.diff(due, DateTime.utc_now(), :day), 365, 1
    assert kase.instance.status == :running

    # The date comes: the case ends.
    assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 366 * 86_400, :second)) >= 1
    kase = the_case(coordinator, credential)
    assert kase.instance.status == :completed
    assert kase.instance.outcome == "recredentialing_due"
  end

  test "opening a case twice returns the open one", %{
    tenant: tenant,
    clinic: clinic,
    coordinator: coordinator
  } do
    credential = clinic.case_credential
    %{"instance_id" => first} = open!(credential, coordinator, tenant)
    assert %{"instance_id" => ^first} = open!(credential, coordinator, tenant)
  end

  test "a person who may not change the credential cannot open its case", %{
    tenant: tenant,
    clinic: clinic
  } do
    member = actor(hd(clinic.committee), tenant)

    assert {:error, %Ash.Error.Forbidden{}} =
             Credentialing.open_case(clinic.case_credential.id, actor: member, tenant: tenant)
  end

  defp decide(task_id, actor, tenant) do
    HumanTask
    |> Ash.ActionInput.for_action(:approve, %{record_id: task_id}, actor: actor, tenant: tenant)
    |> Ash.run_action()
  end
end
