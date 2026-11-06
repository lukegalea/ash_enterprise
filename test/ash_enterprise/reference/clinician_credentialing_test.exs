defmodule AshEnterprise.Reference.ClinicianCredentialingTest do
  @moduledoc """
  The reference scenario, end to end, on the seeded clinic: a clinic credentials its
  clinicians, and each of the twelve failure scenarios (F1–F12) happens to it on the way.

  A regression roll-up. Every failure is also the exit test of the ticket that introduced
  it, and the showcase's slice tests drive the same paths piecemeal; this file walks the
  scenario in its own order, through the application's own actions and the showcase's
  read models, so one file says whether the clinic still holds together:

    * **the reading**: the licence reader reads the synthetic documents into typed findings
      that cite their lines; a model that times out after its lookups resumes without
      looking again (F1); a long bundle stops on its budget and goes on once extended (F8);
      erasing the clinician shreds the run's journal and arguments while the rows and the
      audit chain stay (F11);
    * **the case**: the evidence checks run side by side and one refused by the business
      takes its boundary (F7); the missing document is asked for and awaited, and its
      webhook, early and repeated, moves the case on once (F6); the committee decides, and
      the approved case ends when its re-credentialing timer falls due;
    * **the routing**: a real case waits while the routing table changes, then the engine
      evaluates the table and routes the case by the version its release pinned, while a
      case started after the change takes the new one (F10);
    * **the activation**: one request runs once and records its effect; a correction while
      the approval waits leaves it stale (F4); a revoked grant denies it before the registry
      is asked (F5); a deploy that changes what covers `activate_credential` leaves the
      approval stale (F3);
    * **the release**: a candidate that follows an injected instruction fails the gate
      (F9), and a shadow rerun of the suite activates nobody (F12).

  F2 needs a worker that really dies and a lease that really runs out, so it is the
  durability tier's, below (`AshEnterprise.Reference.ClinicianCredentialingDurabilityTest`).

  Recorded model, synthetic data, the engine's jobs inline and the timers fired by hand.
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  # The clinic's demo data ingests its licence documents into the evidence store.
  @moduletag evidence: true

  require Ash.Query

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Triggers.SweepWorker
  alias AshEnterprise.Bpmn.{Definition, HumanTask, ProcessEvent}
  alias AshEnterprise.Credentialing

  alias AshEnterprise.Credentialing.{
    CaseProcess,
    Credential,
    DemoData,
    DocumentWebhook,
    Registry,
    ReleaseDemoData,
    RoutingTable
  }

  alias AshEnterprise.Erasure.Shredded
  alias AshEnterprise.Execution
  alias AshEnterprise.Faults
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Process.{Binding, Resolver}
  alias AshEnterprise.Quality
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Showcase.Case, as: CaseTour
  alias AshEnterprise.Showcase.Credentialing, as: Tour
  alias AshEnterprise.Showcase.Release
  alias AshEnterprise.Test.Execution.Runs

  @failures for n <- 1..12, do: "F#{n}"

  # A case's review routing on its own: it waits out an evidence window, then asks the
  # clinic's routing table who reviews it and ends on that reviewer. The table is the
  # showcase's (`RoutingTable`); the diagram exists so a running case, not a direct call,
  # evaluates it.
  @routing_process "credentialing.review_routing"
  @routing_release "credentialing.review"
  @routing_xml """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                     xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                     xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                     id="Definitions_review_routing"
                     targetNamespace="https://ash-enterprise.example/bpmn">
    <bpmn2:process id="Process_review_routing" name="Review routing" isExecutable="true">
      <bpmn2:startEvent id="Start"><bpmn2:outgoing>F_start</bpmn2:outgoing></bpmn2:startEvent>
      <bpmn2:intermediateCatchEvent id="EvidenceWindow" name="Evidence window">
        <bpmn2:incoming>F_start</bpmn2:incoming>
        <bpmn2:outgoing>F_window</bpmn2:outgoing>
        <bpmn2:timerEventDefinition id="Timer_window">
          <bpmn2:timeDuration xsi:type="bpmn2:tFormalExpression">PT1H</bpmn2:timeDuration>
        </bpmn2:timerEventDefinition>
      </bpmn2:intermediateCatchEvent>
      <bpmn2:businessRuleTask id="RouteReview" name="Who reviews it?">
        <bpmn2:extensionElements>
          <ash:decision ref="credentialing.review_route" binding="latest"/>
          <ash:inputs><ash:input name="tier" from="&quot;standard&quot;"/></ash:inputs>
          <ash:promote><ash:signal name="route" from="Route" required="true"/></ash:promote>
        </bpmn2:extensionElements>
        <bpmn2:incoming>F_window</bpmn2:incoming>
        <bpmn2:outgoing>F_routed</bpmn2:outgoing>
      </bpmn2:businessRuleTask>
      <bpmn2:exclusiveGateway id="Reviewer" default="F_committee">
        <bpmn2:incoming>F_routed</bpmn2:incoming>
        <bpmn2:outgoing>F_committee</bpmn2:outgoing>
        <bpmn2:outgoing>F_director</bpmn2:outgoing>
      </bpmn2:exclusiveGateway>
      <bpmn2:endEvent id="ToCommittee">
        <bpmn2:extensionElements><ash:taskConfig outcome="committee"/></bpmn2:extensionElements>
        <bpmn2:incoming>F_committee</bpmn2:incoming>
      </bpmn2:endEvent>
      <bpmn2:endEvent id="ToDirector">
        <bpmn2:extensionElements><ash:taskConfig outcome="director"/></bpmn2:extensionElements>
        <bpmn2:incoming>F_director</bpmn2:incoming>
      </bpmn2:endEvent>
      <bpmn2:sequenceFlow id="F_start" sourceRef="Start" targetRef="EvidenceWindow"/>
      <bpmn2:sequenceFlow id="F_window" sourceRef="EvidenceWindow" targetRef="RouteReview"/>
      <bpmn2:sequenceFlow id="F_routed" sourceRef="RouteReview" targetRef="Reviewer"/>
      <bpmn2:sequenceFlow id="F_committee" sourceRef="Reviewer" targetRef="ToCommittee"/>
      <bpmn2:sequenceFlow id="F_director" sourceRef="Reviewer" targetRef="ToDirector">
        <bpmn2:conditionExpression xsi:type="bpmn2:tFormalExpression"
          language="feel">routing.route = "director"</bpmn2:conditionExpression>
      </bpmn2:sequenceFlow>
    </bpmn2:process>
  </bpmn2:definitions>
  """

  setup :clinic

  # The roll-up's own bookkeeping needs no clinic.
  defp clinic(%{failures: _}) do
    TestJobs.clear()
    on_exit(&Faults.disarm_all/0)
    admin = tenant!()
    clinic = DemoData.populate(admin.tenant)

    %{
      admin: admin,
      tenant: admin.tenant,
      clinic: clinic,
      coordinator: actor(clinic.coordinator, admin.tenant),
      director: actor(clinic.director, admin.tenant)
    }
  end

  defp clinic(_context), do: :ok

  defp actor(user, tenant),
    do: ActorContext.attach(user, ActorContext.build(user, tenant: tenant))

  defp credential(clinic, number), do: Enum.find(clinic.credentials, &(&1.number == number))

  # What the runs' `:step` jobs and their tool calls' `:execute` jobs do, until neither
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

  defp drive!(run, tenant) do
    drain!()
    Execution.get_agent_run!(run.id, authorize?: false, tenant: tenant)
  end

  # A suite run's cases settle, then the sweep scores it.
  defp settle! do
    drain!()
    AshOban.Test.schedule_and_run_triggers({Quality.SuiteRun, :finish}, drain_queues?: true)
  end

  defp reading(run, viewer), do: viewer |> Tour.readings() |> Enum.find(&(&1.run.id == run.id))

  # --- the reading ------------------------------------------------------------------

  @tag failures: ~w(F1 F8 F11)
  test "the reader records typed findings that cite their lines; a timeout resumes (F1), a budget stops (F8), an erasure keeps the chain (F11)",
       %{admin: admin, clinic: clinic, tenant: tenant, coordinator: coordinator} = ctx do
    # F1: the model times out after the two lookups; the run resumes from them.
    :ok = Tour.time_out_model_after_lookups()
    {:ok, run} = Tour.start_reading(credential(clinic, "DEMO-RN-0002").id, coordinator)
    assert drive!(run, tenant).status == :running

    reading = reading(run, coordinator)
    assert [%{outcome: :ok}, %{outcome: :error}] = reading.model_calls
    assert [_, _] = reading.lookups

    Runs.elapse_lease!(run)
    interrupted = Execution.get_agent_run!(run.id, authorize?: false, tenant: tenant)

    {:ok, _} =
      Execution.recover_agent_run(interrupted, actor: SystemActor.oban(), tenant: tenant)

    assert drive!(run, tenant).status == :completed

    reading = reading(run, coordinator)
    assert Enum.map(reading.model_calls, & &1.outcome) == [:ok, :error, :ok, :ok]
    assert length(reading.lookups) == 2
    assert Enum.all?(reading.lookups, &(&1.attempt_count == 1))

    # The findings are typed and say which line of the document they rest on.
    found = Map.new(reading.findings, &{&1.question, &1})
    assert found["licence_number"].value == "DEMO-RN-0002"
    assert [%{line: _, text: "Licence number: DEMO-RN-0002"}] = found["licence_number"].lines
    assert found["licence_number"].judgment.run_id == to_string(run.id)

    # F8: a long bundle runs out of budget, says so, and only the director may extend it.
    {:ok, long} = Tour.start_reading(credential(clinic, "DEMO-OT-0003").id, coordinator)
    waiting = drive!(long, tenant)

    assert {waiting.status, waiting.blocked_on, waiting.error_code} ==
             {:waiting, :budget, "token_budget"}

    assert {:error, %Ash.Error.Forbidden{}} = Tour.extend_budget(long.id, 4_000, coordinator)
    assert {:ok, _} = Tour.extend_budget(long.id, 4_000, ctx.director)
    assert drive!(long, tenant).status == :completed

    # F11: the clinician asks to be erased while the audit trail must stay.
    credential = credential(clinic, "DEMO-RN-0002")
    assert {:error, %Ash.Error.Forbidden{}} = Tour.erase_clinician(credential.id, coordinator)

    Seeder.grant_platform_operator(admin.user)
    operator = actor(admin.user, tenant)
    steps = length(reading.steps)
    assert {:ok, %{status: :shredded}} = Tour.erase_clinician(credential.id, operator)

    erased = reading(run, operator)
    assert erased.erased?
    assert length(erased.steps) == steps
    refute Enum.any?(erased.steps, & &1.recorded?)
    assert erased.calls != []
    assert Enum.all?(erased.calls, &Shredded.shredded?(&1.args))
    assert Tour.chain_verifies?(tenant)
  end

  # --- the case ---------------------------------------------------------------------

  @tag failures: ~w(F6 F7)
  test "the case checks side by side (F7), waits for its document once however the webhook arrives (F6), and ends at re-credentialing",
       %{clinic: clinic, tenant: tenant, coordinator: coordinator} do
    credential = clinic.case_credential
    delivery = "delivery-#{System.unique_integer([:positive])}"

    # F6, out of order: the filing system says the document arrived before anyone asked.
    assert DocumentWebhook.deliver(tenant, credential.id, delivery) == :received

    assert %{"status" => "running"} =
             Credentialing.open_case!(credential.id, actor: coordinator, tenant: tenant)

    # F7: the documents check is refused by the business and takes its boundary, which asks
    # for the document once; the expiry check beside it passes.
    kase = the_case(coordinator, credential)
    by_target = Map.new(kase.checks, &{&1.target, &1})

    assert %{status: :failed, error_code: "licence_document_missing"} =
             by_target["AshEnterprise.Credentialing.Credential.check_documents"]

    assert %{status: :succeeded} =
             by_target["AshEnterprise.Credentialing.Credential.check_expiry"]

    assert [%{type: "document.requested"}] = kase.requests

    # The waiting case finds the early delivery, and the sender repeating it wakes nothing.
    sweep!(tenant)
    assert DocumentWebhook.deliver(tenant, credential.id, delivery) == :duplicate
    sweep!(tenant)

    kase = the_case(coordinator, credential)
    assert length(kase.deliveries) == 1
    assert kase.continuations == 1
    refute CaseProcess.await_node() in kase.waiting_for
    assert %{status: :open, id: task_id} = kase.review

    # The committee decides, not the coordinator who owns the credential.
    assert {:error, _} = decide(task_id, coordinator, tenant)
    assert {:ok, _} = decide(task_id, actor(hd(clinic.committee), tenant), tenant)

    kase = the_case(coordinator, credential)
    assert %{due_at: due} = kase.timer
    assert_in_delta DateTime.diff(due, DateTime.utc_now(), :day), 365, 1

    assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 366 * 86_400, :second)) >= 1
    kase = the_case(coordinator, credential)
    assert {kase.instance.status, kase.instance.outcome} == {:completed, "recredentialing_due"}
  end

  defp the_case(actor, credential),
    do: Enum.find(CaseTour.cases(actor), &(&1.credential.id == credential.id))

  defp sweep!(tenant), do: SweepWorker.perform(%Oban.Job{args: %{"tenant" => tenant}})

  defp decide(task_id, actor, tenant) do
    HumanTask
    |> Ash.ActionInput.for_action(:approve, %{record_id: task_id}, actor: actor, tenant: tenant)
    |> Ash.run_action()
  end

  # --- the routing ------------------------------------------------------------------

  @tag failures: ~w(F10)
  test "a running case is routed by the table its release pinned, though the table changed while it waited (F10)",
       %{clinic: clinic, tenant: tenant} do
    publish_routing_process!(tenant)
    first = release_routing!(clinic, tenant)

    [one, two | _] = clinic.credentials
    old = start_routing!(one, clinic, tenant)
    assert old.release_manifest_id == first.id
    assert old.status == :running

    # The table changes while the old case waits, and is released for cases from now on.
    assert {:published, 2} = RoutingTable.publish_next!(tenant)
    second = release_routing!(clinic, tenant)
    assert second.id != first.id

    assert Execution.get_release_manifest!(first.id, authorize?: false, tenant: tenant).status ==
             :superseded

    new = start_routing!(two, clinic, tenant)
    assert new.release_manifest_id == second.id

    # Both cases reach the table now, after the change: the engine evaluates it as each
    # case's release pinned it.
    assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 2 * 3_600, :second)) >= 2

    assert routed(old, tenant) == {:completed, "committee", "1"}
    assert routed(new, tenant) == {:completed, "director", "2"}
  end

  defp publish_routing_process!(tenant) do
    opts = [actor: SystemActor.process(), tenant: tenant]

    definition =
      %{key: @routing_process, name: "Review routing", xml: @routing_xml}
      |> Definition.create!(opts)
      |> Definition.publish!(opts)

    Binding.bind!(
      %{
        kind: :process,
        key: @routing_process,
        source: :tenant,
        target_id: definition.id,
        bound_version: definition.version
      },
      opts
    )
  end

  defp release_routing!(clinic, tenant),
    do:
      ReleaseDemoData.release!(tenant, clinic.director, clinic.deputy, @routing_release, [
        %{kind: "process", key: @routing_process},
        %{kind: "decision", key: RoutingTable.key()}
      ])

  defp start_routing!(credential, clinic, tenant) do
    {:ok, definition} = Resolver.resolve(:process, @routing_process, tenant)

    AshBpmn.start_instance!(AshEnterprise.Bpmn,
      definition: definition,
      subject: credential,
      actor: SystemActor.process(),
      started_by_id: clinic.coordinator.id,
      tenant: tenant
    )
  end

  # `{status, outcome, the table version the engine's decision event names}`.
  defp routed(instance, tenant) do
    opts = [actor: SystemActor.process(), tenant: tenant]
    instance = Ash.get!(AshEnterprise.Bpmn.Instance, instance.id, opts)

    [event] =
      ProcessEvent
      |> Ash.Query.filter(instance_id == ^instance.id and kind == :decision_evaluated)
      |> Ash.read!(opts)

    assert event.data["decision_ref"] == RoutingTable.key()
    assert event.data["rule_ids"] != []
    {instance.status, instance.outcome, event.data["decision_version"]}
  end

  # --- the activation ---------------------------------------------------------------

  @tag failures: ~w(F3 F4 F5)
  test "an activation runs once and records its effect; a correction (F4), a revoked grant (F5) and a deploy (F3) each stop one",
       %{clinic: clinic, tenant: tenant, coordinator: coordinator, director: director} do
    committee = hd(clinic.committee)

    # Approved, it runs once, as the coordinator, and records what the registry answered.
    first = credential(clinic, "DEMO-PT-0001")
    done = coordinator |> ask!(first, tenant) |> approve!(committee, tenant) |> run!(tenant)
    activated = Ash.get!(Credential, first.id, authorize?: false, tenant: tenant)

    assert {done.status, done.owner_id, activated.status} ==
             {:succeeded, clinic.coordinator.id, :active}

    assert {:ok, %{reference: "stub-registry:" <> _ = reference}} = Registry.lookup(first.id)
    assert activated.registry_reference == reference
    assert Registry.activations(first.id) == 1

    # F4: a colleague corrects the credential while its approval waits: stale.
    second = credential(clinic, "DEMO-RN-0002")
    corrected = ask!(coordinator, second, tenant)
    assert {:ok, _} = Tour.correct_during_approval(second.id, tenant)
    stale = corrected |> approve!(committee, tenant) |> run!(tenant)
    assert {stale.status, stale.error_code} == {:stale, "subject_changed"}
    assert Registry.activations(second.id) == 0

    # F5: the coordinator's role is removed before the activation runs: denied, and the
    # registry is never asked.
    third = credential(clinic, "DEMO-OT-0003")
    revoked = ask!(coordinator, third, tenant)
    assert {:ok, removed} = Tour.revoke_requester_grant(tenant)
    assert removed > 0
    denied = revoked |> approve!(committee, tenant) |> run!(tenant)
    assert {denied.status, denied.failure_class} == {:failed, :denied}
    assert Registry.activations(third.id) == 0

    # F3: with the role back, a request waits while a deploy changes the release covering
    # `activate_credential`: its approval binds the old one, so it is stale when decided.
    assert {:ok, _} = Tour.restore(tenant)
    coordinator = actor(clinic.coordinator, tenant)
    redeployed = ask!(coordinator, third, tenant)
    %{release: release} = Release.read(director, []).activation
    assert redeployed.release_manifest_id == release.id

    assert {:ok, %{status: :active}} = Release.deploy_change(tenant)
    stale = redeployed |> approve!(committee, tenant) |> run!(tenant)
    assert {stale.status, stale.error_code} == {:stale, "manifest_changed"}
    assert Registry.activations(third.id) == 0
  end

  defp ask!(coordinator, credential, tenant) do
    assert {:ok, %{"invocation_id" => id}} =
             Credentialing.request_activation(credential.id, actor: coordinator, tenant: tenant)

    row = Execution.get_invocation!(id, authorize?: false, tenant: tenant)
    assert row.status == :awaiting_approval
    row
  end

  # A member's tasks are in their actor context, so it is built once the task is open.
  defp approve!(row, member, tenant) do
    task = Ash.load!(row, :approval_task, authorize?: false).approval_task
    assert {:ok, _} = decide(task.id, actor(member, tenant), tenant)
    row
  end

  # What the `:apply_decision` job and then the `:execute` job do.
  defp run!(row, tenant) do
    Execution.apply_invocation_decision!(row, actor: SystemActor.oban(), tenant: tenant)
    Oban.drain_queue(queue: :execution)
    Execution.get_invocation!(row.id, authorize?: false, tenant: tenant)
  end

  # --- the release ------------------------------------------------------------------

  @tag failures: ~w(F9 F12)
  test "a candidate that follows an injected instruction fails the gate (F9); a shadow rerun activates nobody (F12)",
       %{tenant: tenant, director: director} do
    # F9: the candidate passes the plain case and fails the injected one.
    assert {:ok, _run} = Release.measure(director)
    settle!()

    %{candidate: candidate} = Release.read(director, [])
    assert candidate.run.status == :finished
    assert %{"failed_cases" => ["injected"]} = candidate.lanes["injection"]
    assert {:error, error} = Release.request(director)
    assert Exception.message(error) =~ "injection"

    # F12: the same cases again, in shadow: every call answered from fixtures, nobody
    # activated.
    before = activations(tenant)
    assert {:ok, %{mode: :shadow}} = Release.shadow(director)
    settle!()

    assert [%{run: %{status: :finished}, calls: calls}] = Release.read(director, []).shadow
    assert Enum.any?(calls, &String.ends_with?(&1.target, "request_activation"))
    assert Enum.all?(calls, &(&1.simulated? and &1.status == :succeeded))
    assert activations(tenant) == before
  end

  defp activations(tenant) do
    Execution.list_invocations!(
      authorize?: false,
      tenant: tenant,
      query: [filter: [target: Tour.target()]]
    )
    |> Enum.map(&{&1.id, &1.status})
    |> Enum.sort()
  end

  # --- the roll-up ------------------------------------------------------------------

  test "every one of the twelve failures is exercised here" do
    tagged =
      for module <- [__MODULE__, AshEnterprise.Reference.ClinicianCredentialingDurabilityTest],
          test <- module.__ex_unit__().tests,
          failure <- Map.get(test.tags, :failures, []),
          into: MapSet.new(),
          do: failure

    assert Enum.sort(tagged) == Enum.sort(@failures)
  end
end

defmodule AshEnterprise.Reference.ClinicianCredentialingDurabilityTest do
  @moduledoc """
  F2 of the reference scenario, on the durability tier: the worker activating a credential
  dies after the registry accepted it and before anything was recorded. The lease it held
  keeps the request from running again; when it runs out, the reconcile sweep asks the
  registry (`reconcile_with`) and settles the request with the registry's reference. The
  registry took the activation once.
  """

  use AshEnterprise.DurabilityCase, async: false

  import AshEnterprise.Test.Execution.Durable

  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.{Credential, DemoData, Registry}
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Invocation.{ReconcileScheduler, ReconcileWorker}
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Showcase.Credentialing, as: Tour

  setup do
    subscribe_jobs()
    %{tenant: tenant} = clinic!()
    %{tenant: tenant, clinic: DemoData.populate(tenant)}
  end

  defp actor(user, tenant),
    do: ActorContext.attach(user, ActorContext.build(user, tenant: tenant))

  @tag failures: ~w(F2)
  test "the worker dies after the registry accepted: unknown, reconciled, not repeated (F2)",
       %{tenant: tenant, clinic: clinic} do
    [credential | _] = clinic.credentials
    coordinator = actor(clinic.coordinator, tenant)

    assert {:ok, %{"invocation_id" => id}} =
             Credentialing.request_activation(credential.id, actor: coordinator, tenant: tenant)

    row = committed(id, tenant)
    assert row.status == :awaiting_approval
    assert :ok = Tour.kill_after_registry_accepts()

    task = Ash.load!(row, :approval_task, authorize?: false).approval_task

    HumanTask
    |> Ash.ActionInput.for_action(:approve, %{record_id: task.id},
      actor: actor(hd(clinic.committee), tenant),
      tenant: tenant
    )
    |> Ash.run_action!()

    # Applied as the `:apply_decision` job applies it; the real `:execute` job it enqueues
    # is killed between the registry and the record.
    row = Execution.apply_invocation_decision!(row, oban(tenant))
    assert row.status == :ready
    [job] = jobs(row.id)
    assert %{kind: :exit} = await_job(job.id, :failure)

    held = committed(row.id, tenant)
    assert {held.status, held.lease_epoch} == {:executing, 1}
    assert Registry.activations(credential.id) == 1

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

    # The worker that died wrote nothing on the credential itself.
    assert Ash.get!(Credential, credential.id, authorize?: false, tenant: tenant).status ==
             :pending
  end
end
