defmodule AshEnterprise.Bridge.WorkflowWaitsForAgentWaitingForHumanTest do
  @moduledoc """
  PLAT-08 and F6: a process hands work to an agent and waits for it, the agent waits for a
  person, and nothing is done twice however the pieces are killed or repeated.

      process:  start the agent run -> wait for the run's finish -> read how it ended -> route
      agent:    ask the clinician a question -> (days) -> answer -> finish
      person:   answers

  The process waits on a receive task for the run's CloudEvents envelope
  (`AshEnterprise.Execution.RunFinished`), correlated on the run's id, with a timer boundary
  for the timeout. The tests kill the worker at each hop and check that the survivors finish
  the job once:

    * the process starts the run and dies before its token moves on;
    * the run finishes, and its worker dies with the run final and announced but not
      committed;
    * the envelope is committed and the sweep that delivers it dies mid-delivery.

  A finish that comes before the wait, and a finish delivered twice, move the process on
  once. Cancelling the instance cancels its run, and a timeout cancels the run it stops
  waiting for, then reads how the run ended and routes on that: a run that finished while
  its message was never heard (a wait that began after the lookback window, a sweep that
  was down) is not reported as timed out.

  Committed for real, with a real Oban whose agent queues are paused so each test drives
  every step by hand. The process engine's own jobs run inline, as in every test. SYNTHETIC
  data only.
  """

  use AshEnterprise.DurabilityCase, async: false

  # Each test publishes an agent under four eyes, starts a process and drives a run: a minute
  # on a busy host is not enough.
  @moduletag timeout: 300_000

  import AshEnterprise.Test.Execution.Runs
  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias AshBpmn.Runtime.AdvanceWorker
  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Triggers.SweepWorker
  alias AshEnterprise.Bpmn.{HumanTask, ProcessEvent}
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.{HumanInput, Run}
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Test.DailyFixtures
  alias AshEnterprise.Test.Execution.Intake
  alias AshEnterprise.Test.Process.EvidenceChecks

  @ask "human_input_request"

  @process """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                     xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                     xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                     id="Definitions_agent_work"
                     targetNamespace="https://github.com/lukegalea/ash_bpmn/ns">
    <bpmn2:process id="Process_agent_work" name="Hand work to an agent" isExecutable="true">
      <bpmn2:startEvent id="Start"><bpmn2:outgoing>F1</bpmn2:outgoing></bpmn2:startEvent>

      <bpmn2:serviceTask id="StartRun" name="Ask the agent">
        <bpmn2:extensionElements>
          <ash:taskConfig action="start_agent_run"/>
          <ash:inputs>
            <ash:input name="agent" from="&quot;AGENT&quot;"/>
            <ash:input name="input" from="&quot;SYNTHETIC: take the intake for the new referral.&quot;"/>
          </ash:inputs>
          <ash:promote><ash:signal name="run_id" required="true"/></ash:promote>
        </bpmn2:extensionElements>
        <bpmn2:incoming>F1</bpmn2:incoming>
        <bpmn2:outgoing>F2</bpmn2:outgoing>
      </bpmn2:serviceTask>

      <bpmn2:receiveTask id="AwaitRun" name="Wait for the agent">
        <bpmn2:extensionElements>
          <ash:subscribe resource="AshEnterprise.Execution.RunFinished" action="emit"
                         correlate="routing.run_id" match="data.subject" lookback="10"/>
        </bpmn2:extensionElements>
        <bpmn2:incoming>F2</bpmn2:incoming>
        <bpmn2:outgoing>F3</bpmn2:outgoing>
      </bpmn2:receiveTask>

      <bpmn2:boundaryEvent id="TooSlow" name="No answer in time" attachedToRef="AwaitRun">
        <bpmn2:outgoing>F_slow</bpmn2:outgoing>
        <bpmn2:timerEventDefinition id="Timer_slow">
          <bpmn2:timeDuration xsi:type="bpmn2:tFormalExpression">P14D</bpmn2:timeDuration>
        </bpmn2:timerEventDefinition>
      </bpmn2:boundaryEvent>

      <bpmn2:serviceTask id="ReadOutcome" name="Read how it ended">
        <bpmn2:extensionElements>
          <ash:taskConfig action="agent_run_outcome"/>
          <ash:inputs><ash:input name="run_id" from="routing.run_id"/></ash:inputs>
          <ash:promote><ash:signal name="outcome" required="true"/></ash:promote>
        </bpmn2:extensionElements>
        <bpmn2:incoming>F3</bpmn2:incoming>
        <bpmn2:incoming>F_stopped</bpmn2:incoming>
        <bpmn2:outgoing>F4</bpmn2:outgoing>
      </bpmn2:serviceTask>

      <bpmn2:exclusiveGateway id="Route" default="F_other">
        <bpmn2:incoming>F4</bpmn2:incoming>
        <bpmn2:outgoing>F_done</bpmn2:outgoing>
        <bpmn2:outgoing>F_cancelled</bpmn2:outgoing>
        <bpmn2:outgoing>F_other</bpmn2:outgoing>
      </bpmn2:exclusiveGateway>

      <bpmn2:serviceTask id="StopRun" name="Stop the agent">
        <bpmn2:extensionElements>
          <ash:taskConfig action="cancel_agent_run"/>
          <ash:inputs><ash:input name="run_id" from="routing.run_id"/></ash:inputs>
        </bpmn2:extensionElements>
        <bpmn2:incoming>F_slow</bpmn2:incoming>
        <bpmn2:outgoing>F_stopped</bpmn2:outgoing>
      </bpmn2:serviceTask>

      <bpmn2:endEvent id="Finished">
        <bpmn2:extensionElements><ash:taskConfig outcome="agent_completed"/></bpmn2:extensionElements>
        <bpmn2:incoming>F_done</bpmn2:incoming>
      </bpmn2:endEvent>
      <bpmn2:endEvent id="NotFinished">
        <bpmn2:extensionElements><ash:taskConfig outcome="agent_did_not_complete"/></bpmn2:extensionElements>
        <bpmn2:incoming>F_other</bpmn2:incoming>
      </bpmn2:endEvent>
      <bpmn2:endEvent id="TimedOut">
        <bpmn2:extensionElements><ash:taskConfig outcome="agent_timed_out"/></bpmn2:extensionElements>
        <bpmn2:incoming>F_cancelled</bpmn2:incoming>
      </bpmn2:endEvent>

      <bpmn2:sequenceFlow id="F1" sourceRef="Start" targetRef="StartRun"/>
      <bpmn2:sequenceFlow id="F2" sourceRef="StartRun" targetRef="AwaitRun"/>
      <bpmn2:sequenceFlow id="F3" sourceRef="AwaitRun" targetRef="ReadOutcome"/>
      <bpmn2:sequenceFlow id="F4" sourceRef="ReadOutcome" targetRef="Route"/>
      <bpmn2:sequenceFlow id="F_done" sourceRef="Route" targetRef="Finished">
        <bpmn2:conditionExpression xsi:type="bpmn2:tFormalExpression"
          language="feel">routing.outcome = "completed"</bpmn2:conditionExpression>
      </bpmn2:sequenceFlow>
      <bpmn2:sequenceFlow id="F_other" sourceRef="Route" targetRef="NotFinished"/>
      <bpmn2:sequenceFlow id="F_slow" sourceRef="TooSlow" targetRef="StopRun"/>
      <bpmn2:sequenceFlow id="F_stopped" sourceRef="StopRun" targetRef="ReadOutcome"/>
      <bpmn2:sequenceFlow id="F_cancelled" sourceRef="Route" targetRef="TimedOut">
        <bpmn2:conditionExpression xsi:type="bpmn2:tFormalExpression"
          language="feel">routing.outcome = "cancelled"</bpmn2:conditionExpression>
      </bpmn2:sequenceFlow>
    </bpmn2:process>
  </bpmn2:definitions>
  """

  # The run is started by the parent and handed to the child below (see the test): a child a
  # call activity starts does not inherit who started its parent, so it cannot start a run as
  # that person itself.
  @parent """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                     xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                     id="Definitions_intake_parent"
                     targetNamespace="https://github.com/lukegalea/ash_bpmn/ns">
    <bpmn2:process id="Process_intake_parent" name="Intake, drawn once" isExecutable="true">
      <bpmn2:startEvent id="Start"><bpmn2:outgoing>F1</bpmn2:outgoing></bpmn2:startEvent>
      <bpmn2:serviceTask id="StartRun" name="Ask the agent">
        <bpmn2:extensionElements>
          <ash:taskConfig action="start_agent_run"/>
          <ash:inputs>
            <ash:input name="agent" from="&quot;AGENT&quot;"/>
            <ash:input name="input" from="&quot;SYNTHETIC: take the intake for the new referral.&quot;"/>
          </ash:inputs>
          <ash:promote><ash:signal name="run_id" required="true"/></ash:promote>
        </bpmn2:extensionElements>
        <bpmn2:incoming>F1</bpmn2:incoming>
        <bpmn2:outgoing>F2</bpmn2:outgoing>
      </bpmn2:serviceTask>
      <bpmn2:callActivity id="Intake" name="Intake">
        <bpmn2:extensionElements><ash:process key="CHILD_KEY"/></bpmn2:extensionElements>
        <bpmn2:incoming>F2</bpmn2:incoming>
        <bpmn2:outgoing>F3</bpmn2:outgoing>
      </bpmn2:callActivity>
      <bpmn2:endEvent id="End"><bpmn2:incoming>F3</bpmn2:incoming></bpmn2:endEvent>
      <bpmn2:sequenceFlow id="F1" sourceRef="Start" targetRef="StartRun"/>
      <bpmn2:sequenceFlow id="F2" sourceRef="StartRun" targetRef="Intake"/>
      <bpmn2:sequenceFlow id="F3" sourceRef="Intake" targetRef="End"/>
    </bpmn2:process>
  </bpmn2:definitions>
  """

  @child """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                     xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                     id="Definitions_intake_review"
                     targetNamespace="https://github.com/lukegalea/ash_bpmn/ns">
    <bpmn2:process id="Process_intake_review" name="Review the intake" isExecutable="true">
      <bpmn2:startEvent id="Start"><bpmn2:outgoing>F1</bpmn2:outgoing></bpmn2:startEvent>
      <bpmn2:userTask id="Review" name="Review">
        <bpmn2:extensionElements>
          <ash:taskConfig>
            <ash:candidates><ash:candidate kind="role" of="Administrator"/></ash:candidates>
            <ash:outcomes><ash:outcome name="done"/></ash:outcomes>
          </ash:taskConfig>
        </bpmn2:extensionElements>
        <bpmn2:incoming>F1</bpmn2:incoming>
        <bpmn2:outgoing>F2</bpmn2:outgoing>
      </bpmn2:userTask>
      <bpmn2:endEvent id="End"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
      <bpmn2:sequenceFlow id="F1" sourceRef="Start" targetRef="Review"/>
      <bpmn2:sequenceFlow id="F2" sourceRef="Review" targetRef="End"/>
    </bpmn2:process>
  </bpmn2:definitions>
  """

  setup do
    in_zone!()
    pause_queues!()
    TestJobs.clear()
    clinic = clinic!()
    %{clinic: clinic}
  end

  # What the process is about: a clinician's licence, as in the credentialing showcase.
  defp credential!(%{admin: admin, tenant: tenant}) do
    as_admin = [actor: admin.actor, tenant: tenant]
    n = System.unique_integer([:positive])

    clinic = Credentialing.register_clinic!("Synthetic clinic #{n}", as_admin)

    clinician =
      Credentialing.register_clinician!(
        %{
          first_name: "Ada",
          last_name: "Synthetic",
          job_title: "Practice nurse",
          clinic_id: clinic.id
        },
        as_admin
      )

    Credentialing.record_credential!(
      %{
        kind: :licence,
        number: "DEMO-RN-#{n}",
        expires_on: Date.add(Date.utc_today(), 365),
        clinician_id: clinician.id
      },
      as_admin
    )
  end

  # The process, published in the clinic, asking the agent keyed `agent`.
  defp process!(clinic, agent) do
    EvidenceChecks.publish!(clinic, String.replace(@process, "AGENT", agent))
  end

  defp process_with_child!(clinic, agent, child) do
    xml = @parent |> String.replace("AGENT", agent) |> String.replace("CHILD_KEY", child.key)
    EvidenceChecks.publish!(clinic, xml)
  end

  # The nurse starts an instance of `definition`: the engine acts as the process actor, and
  # the nurse is the person it runs the agent as.
  defp start_instance(clinic, definition, credential) do
    AshBpmn.start_instance!(AshEnterprise.Bpmn,
      definition: definition,
      subject: credential,
      actor: SystemActor.process(),
      started_by_id: clinic.nurse.user.id,
      tenant: clinic.tenant
    )
  end

  # Runs `fun` in a process of its own and waits for it to be killed outright.
  defp killed(fun) do
    {pid, ref} = spawn_monitor(fun)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 30_000
  end

  defp tenant_opts(clinic), do: [actor: SystemActor.process(), tenant: clinic.tenant]

  defp runs(clinic) do
    Execution.list_agent_runs!(Keyword.put(tenant_opts(clinic), :authorize?, false))
  end

  defp announcements(clinic) do
    Execution.list_run_finished!(actor: SystemActor.oban(), tenant: clinic.tenant)
  end

  defp instance(clinic, definition), do: EvidenceChecks.instance!(clinic, definition)

  defp token_status(clinic, instance, node) do
    clinic |> EvidenceChecks.tokens_at(instance, node) |> Enum.map(& &1.status)
  end

  defp heard(clinic, instance) do
    id = instance.id

    ProcessEvent
    |> Ash.Query.filter(instance_id == ^id and kind == :message_received)
    |> Ash.read!(tenant: clinic.tenant, authorize?: false)
  end

  # The claim of the worker that died holding the token ages past the engine's claim timeout,
  # which is when a retry may take it back. Written past the actions, as the clock is.
  defp claim_lapses!(token) do
    past = DateTime.add(DateTime.utc_now(), -3_600, :second)

    {1, _} =
      AshEnterprise.Repo.update_all(
        from(t in "bpmn_tokens", where: t.id == type(^token.id, Ecto.UUID)),
        set: [updated_at: past]
      )

    :ok
  end

  defp pause_engine_queue, do: Oban.pause_queue(queue: AshBpmn.Config.queue())
  defp resume_engine_queue, do: Oban.resume_queue(queue: AshBpmn.Config.queue())

  # The advance job the engine queued for `instance`'s token at `node_id`.
  defp advance_job!(instance, node_id) do
    id = instance.id

    jobs =
      Repo.all(
        from(j in Oban.Job,
          where:
            j.worker == "AshBpmn.Runtime.AdvanceWorker" and
              fragment("?->>'instance_id' = ?", j.args, ^id) and
              fragment("?->>'node_id' = ?", j.args, ^node_id)
        )
      )

    [job] = jobs
    job
  end

  # The sweep the cron fans out to this tenant: delivers what is in the log past the cursor.
  defp sweep!(clinic), do: SweepWorker.perform(%Oban.Job{args: %{"tenant" => clinic.tenant}})

  defp task(row, key, tenant) do
    id = row.id

    HumanTask
    |> Ash.Query.filter(subject_id == ^id and node_id == ^key)
    |> Ash.read_one!(authorize?: false, tenant: tenant)
  end

  # The run's question reaches the nurse, and she answers it: the invocation is dispatched,
  # then collected once the answer is in.
  defp nurse_answers!(%{nurse: nurse, tenant: tenant}, run, answer) do
    Oban.drain_queue(queue: :agent_runs)
    assert %{status: :waiting, blocked_on: :tools} = run(run)
    assert [%{status: :ready} = asked] = invocations(run)

    Oban.drain_queue(queue: :execution)
    asked = Ash.reload!(asked, authorize?: false, tenant: tenant)
    assert asked.status == :dispatched

    assert {:ok, _} =
             HumanTask
             |> Ash.ActionInput.for_action(
               :answer,
               %{record_id: task(asked, HumanInput.key(), tenant).id, answer: answer},
               actor: DailyFixtures.actor(nurse.user),
               tenant: tenant
             )
             |> Ash.run_action()

    Oban.insert!(Execution.Invocation.CollectInputScheduler.new(%{}))
    Oban.drain_queue(queue: :execution, with_recursion: true)
    assert %{status: :succeeded} = Ash.reload!(asked, authorize?: false, tenant: tenant)
  end

  defp question_script!(extra_texts) do
    script!(
      [
        {:tools, [{"call_ask", @ask, %{"input" => %{"question" => "SYNTHETIC: which ward?"}}}]},
        {:text, ~s({"ward": "4B"})}
      ] ++ for(text <- extra_texts, do: {:text, text})
    )
  end

  test "a process waits for an agent that waits for a person, and every kill leaves it finishing once",
       %{clinic: clinic} do
    published!(clinic, %{}, Intake)
    credential = credential!(clinic)
    definition = process!(clinic, "clinic.intake")
    question_script!([~s({"ward": "4B"})])

    # Hop 1: the process starts the run and dies before its token moves on.
    Faults.arm(:process_agent_run_started, :kill)
    killed(fn -> start_instance(clinic, definition, credential) end)

    instance = instance(clinic, definition)

    assert [%{node_id: "StartRun"} = token] =
             EvidenceChecks.tokens_at(clinic, instance, "StartRun")

    assert [run] = runs(clinic)
    assert run.run_key == "bpmn:#{instance.id}:#{token.id}:StartRun"

    assert {run.origin, run.process_instance_id, run.owner_id} ==
             {:bpmn, instance.id, clinic.nurse.user.id}

    # The redelivery, once the dead worker's claim has lapsed, finds that run and starts
    # none; the token parks at the wait, listening
    # for this run and no other.
    claim_lapses!(token)

    assert {:ok, :advanced} =
             AdvanceWorker.perform(EvidenceChecks.retry_job(clinic, instance, token, 2))

    assert [%{id: run_id}] = runs(clinic)
    assert run_id == run.id

    assert [%{status: :waiting, correlation_key: key}] =
             EvidenceChecks.tokens_at(clinic, instance, "AwaitRun")

    assert key == run.id

    # A tenant whose only listener is this parked task is still swept every minute.
    assert clinic.tenant in AshEnterprise.Bpmn.Subscription.trigger_tenants()

    # The agent asks the nurse, who answers. The run is ready for the step that finishes it.
    nurse_answers!(clinic, run, "SYNTHETIC: ward 4B")
    assert announcements(clinic) == []

    # Hop 2: the step that finishes the run dies with the run final and announced, and
    # nothing committed. The run and the process are exactly as they were.
    Faults.arm(:agent_run_finished_announced, :kill)
    killed(fn -> step!(run) end)

    assert %{status: :running, lease_epoch: epoch} = run(run)
    assert announcements(clinic) == []
    assert token_status(clinic, instance, "AwaitRun") == [:waiting]

    # The lease runs out, the run is queued again and its next step finishes it: one
    # announcement, named for the run and the epoch it finished under, as CloudEvents 1.0 says.
    elapse_lease!(run)
    Oban.insert!(Run.RecoverScheduler.new(%{}))
    Oban.drain_queue(queue: :agent_runs, with_recursion: true)
    assert %{status: :completed, lease_epoch: finished_epoch} = run(run)
    assert finished_epoch == epoch + 1

    assert [message] = announcements(clinic)

    assert %{
             specversion: "1.0",
             event_id: event_id,
             source: source,
             type: "agent.run.finished",
             subject: subject,
             datacontenttype: "application/json",
             data: %{"status" => "completed"}
           } = message

    assert {event_id, source, subject} ==
             {"#{run.id}:#{finished_epoch}", "/execution/runs/#{run.id}", run.id}

    # The process has not heard yet.
    assert token_status(clinic, instance, "AwaitRun") == [:waiting]

    # Hop 3, as the engine's inline mode runs it: the sweep dies in the middle of delivering
    # the message, and the advance runs inside the sweep's transaction, so nothing of the
    # delivery survives and the next sweep delivers it. (With the engine queueing as it does
    # in production, the wake is committed first: the test after the timeout one.)
    Faults.arm(:process_agent_run_outcome_read, :kill)
    killed(fn -> sweep!(clinic) end)
    assert instance(clinic, definition).status == :running

    sweep!(clinic)

    done = instance(clinic, definition)
    assert {done.status, done.outcome} == {:completed, "agent_completed"}
    assert [_one] = heard(clinic, instance)
    assert token_status(clinic, instance, "AwaitRun") == [:consumed]
    assert length(runs(clinic)) == 1
    assert length(announcements(clinic)) == 1
  end

  test "a finish that comes before the wait, and a finish delivered twice, move the process on once",
       %{clinic: clinic} do
    published!(clinic)
    credential = credential!(clinic)
    definition = process!(clinic, agent())
    script!([{:text, ~s({"recorded": 0})}])

    # The process starts the run and dies before its token moves on; the run finishes first.
    Faults.arm(:process_agent_run_started, :kill)
    killed(fn -> start_instance(clinic, definition, credential) end)

    instance = instance(clinic, definition)
    [token] = EvidenceChecks.tokens_at(clinic, instance, "StartRun")
    [run] = runs(clinic)

    step!(run)
    assert %{status: :completed} = run(run)
    assert [message] = announcements(clinic)

    # The message is on file before anything waits for it. The process reaches the wait,
    # looks back for what it missed, and moves on.
    claim_lapses!(token)

    assert {:ok, :advanced} =
             AdvanceWorker.perform(EvidenceChecks.retry_job(clinic, instance, token, 2))

    done = instance(clinic, definition)
    assert {done.status, done.outcome} == {:completed, "agent_completed"}
    assert [_one] = heard(clinic, instance)

    # The same envelope again is refused: a consumer dedupes on source and id, and so does
    # the table.
    assert {:error, _duplicate} =
             Execution.emit_run_finished(
               Map.take(message, [:event_id, :source, :type, :subject, :time, :data]),
               actor: SystemActor.oban(),
               tenant: clinic.tenant
             )

    assert length(announcements(clinic)) == 1

    # The sweep reads the log from its cursor, so it hears the message too, and again when
    # the cursor is put back: the process does not move twice.
    sweep!(clinic)

    {1, _} =
      AshEnterprise.Repo.update_all(
        from(c in "bpmn_cursors", where: c.organization_id == type(^clinic.tenant, Ecto.UUID)),
        set: [last_sequence: 0]
      )

    sweep!(clinic)

    assert [_one] = heard(clinic, instance)
    assert %{status: :completed, outcome: "agent_completed"} = instance(clinic, definition)
    assert length(runs(clinic)) == 1
  end

  test "cancelling the instance cancels the run it started", %{clinic: clinic} do
    published!(clinic, %{}, Intake)
    credential = credential!(clinic)
    definition = process!(clinic, "clinic.intake")
    question_script!([])

    instance = start_instance(clinic, definition, credential)
    assert [run] = runs(clinic)
    Oban.drain_queue(queue: :agent_runs)
    assert %{status: :waiting} = run(run)

    # Nothing happens to the run until the instance is cancelled.
    Oban.insert!(Run.CancelWithInstanceScheduler.new(%{}))
    Oban.drain_queue(queue: :agent_runs, with_recursion: true)
    assert %{status: :waiting} = run(run)

    AshBpmn.cancel_instance!(instance, tenant: clinic.tenant, actor: SystemActor.process())

    Oban.insert!(Run.CancelWithInstanceScheduler.new(%{}))
    Oban.drain_queue(queue: :agent_runs, with_recursion: true)

    assert %{status: :cancelled} = run(run)
    assert [%{data: %{"status" => "cancelled"}}] = announcements(clinic)

    # The announcement finds no one waiting: the cancelled instance stays cancelled.
    sweep!(clinic)
    assert %{status: :cancelled} = instance(clinic, definition)
    assert heard(clinic, instance) == []
  end

  test "cancelling the parent cancels the child its call activity started, and the child's run",
       %{clinic: clinic} do
    published!(clinic, %{}, Intake)
    credential = credential!(clinic)
    child = EvidenceChecks.publish!(clinic, @child)
    parent = process_with_child!(clinic, "clinic.intake", child)
    question_script!([])

    parent_instance = start_instance(clinic, parent, credential)
    child_instance = instance(clinic, child)
    assert child_instance.status == :running
    assert [run] = runs(clinic)
    Oban.drain_queue(queue: :agent_runs)
    assert %{status: :waiting} = run(run)

    # Hand the run to the child, as a run the child would have started: the trigger finds a
    # run by its own instance's status, and only the cascade changes the child's.
    id = run.id
    child_id = child_instance.id

    {1, _} =
      AshEnterprise.Repo.update_all(
        from(r in "exec_agent_runs", where: r.id == type(^id, Ecto.UUID)),
        set: [process_instance_id: Ecto.UUID.dump!(child_id)]
      )

    Oban.insert!(Run.CancelWithInstanceScheduler.new(%{}))
    Oban.drain_queue(queue: :agent_runs, with_recursion: true)
    assert %{status: :waiting} = run(run)

    nurse = clinic.nurse.user

    AshBpmn.cancel_instance!(parent_instance,
      tenant: clinic.tenant,
      actor: nurse,
      reason: "referral withdrawn"
    )

    assert %{status: :cancelled} = instance(clinic, child)

    assert [event] =
             ProcessEvent
             |> Ash.Query.filter(
               instance_id == ^child_instance.id and kind == :instance_cancelled
             )
             |> Ash.read!(tenant: clinic.tenant, authorize?: false)

    assert event.data == %{
             "cancelled_by_id" => nurse.id,
             "reason" => "referral withdrawn",
             "cascaded_from_instance_id" => parent_instance.id
           }

    Oban.insert!(Run.CancelWithInstanceScheduler.new(%{}))
    Oban.drain_queue(queue: :agent_runs, with_recursion: true)
    assert %{status: :cancelled} = run(run)
  end

  test "a timeout leaves the wait and cancels the run the process stopped waiting for",
       %{clinic: clinic} do
    published!(clinic, %{}, Intake)
    credential = credential!(clinic)
    definition = process!(clinic, "clinic.intake")
    question_script!([])

    instance = start_instance(clinic, definition, credential)
    assert [run] = runs(clinic)
    Oban.drain_queue(queue: :agent_runs)
    assert %{status: :waiting} = run(run)
    assert token_status(clinic, instance, "AwaitRun") == [:waiting]

    # Nothing is due yet; a fortnight later the boundary's timer is.
    assert TestJobs.fire_due!(DateTime.utc_now()) == 0
    assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 15 * 86_400, :second)) >= 1

    done = instance(clinic, definition)
    assert {done.status, done.outcome} == {:completed, "agent_timed_out"}
    assert %{status: :cancelled} = run(run)
    assert heard(clinic, instance) == []
  end

  test "a run that finished while the wake was lost is read, not cancelled, when the wait times out",
       %{clinic: clinic} do
    published!(clinic)
    credential = credential!(clinic)
    definition = process!(clinic, agent())
    script!([{:text, ~s({"recorded": 0})}])

    # The run is started and the token parks; the run finishes and its message is on file,
    # but nothing delivers it: the sweep is down, or the wait started after the window the
    # lookback reads. The wake is lost.
    Faults.arm(:process_agent_run_started, :kill)
    killed(fn -> start_instance(clinic, definition, credential) end)
    instance = instance(clinic, definition)
    [token] = EvidenceChecks.tokens_at(clinic, instance, "StartRun")
    [run] = runs(clinic)

    step!(run)
    assert %{status: :completed} = run(run)
    assert [_message] = announcements(clinic)

    # Parked after the window (the log was never read), a fortnight passes unheard.
    claim_lapses!(token)
    Faults.disarm_all()
    token_job = EvidenceChecks.retry_job(clinic, instance, token, 2)
    AshEnterprise.Repo.query!("UPDATE bpmn_cursors SET last_sequence = last_sequence + 100000")
    assert {:ok, :advanced} = AdvanceWorker.perform(token_job)
    assert token_status(clinic, instance, "AwaitRun") == [:waiting]

    assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 15 * 86_400, :second)) >= 1

    # The process timed out, but the run had completed: it routes on what the run recorded.
    done = instance(clinic, definition)
    assert {done.status, done.outcome} == {:completed, "agent_completed"}
    assert %{status: :completed} = run(run)
  end

  test "a wake committed to the queue survives a worker that dies reading the outcome",
       %{clinic: clinic} do
    published!(clinic)
    credential = credential!(clinic)
    definition = process!(clinic, agent())
    script!([{:text, ~s({"recorded": 0})}])

    instance = start_instance(clinic, definition, credential)
    [run] = runs(clinic)
    assert token_status(clinic, instance, "AwaitRun") == [:waiting]

    step!(run)
    assert %{status: :completed} = run(run)

    # In production the sweep's delivery commits the wake and its claim, and the advance runs
    # later as a job of its own: the engine queues rather than running inline. That job is
    # picked up by a worker that dies holding the claim on the node it reaches.
    # The engine's queue is paused so that no worker of the tier's own takes the job, and
    # the test runs it, and dies in it, itself.
    Application.put_env(:ash_bpmn, :oban_testing, nil)
    pause_engine_queue()

    on_exit(fn ->
      Application.put_env(:ash_bpmn, :oban_testing, :inline)
      resume_engine_queue()
    end)

    Faults.arm(:process_agent_run_outcome_read, :kill)
    sweep!(clinic)

    assert [_one] = heard(clinic, instance)
    assert token_status(clinic, instance, "AwaitRun") == [:consumed]

    assert [%{status: :active} = read] =
             EvidenceChecks.tokens_at(clinic, instance, "ReadOutcome")

    assert instance(clinic, definition).status == :running

    # The job is this test's own: the queue is shared with every other test's leftovers.
    job = advance_job!(instance, "ReadOutcome")
    killed(fn -> AdvanceWorker.perform(job) end)
    assert instance(clinic, definition).status == :running
    assert token_status(clinic, instance, "ReadOutcome") == [:executing]

    # Only a retry of the job, once the dead worker's claim has lapsed, takes the node back.
    Application.put_env(:ash_bpmn, :oban_testing, :inline)
    claim_lapses!(read)

    assert {:ok, :advanced} =
             AdvanceWorker.perform(EvidenceChecks.retry_job(clinic, instance, read, 2))

    done = instance(clinic, definition)
    assert {done.status, done.outcome} == {:completed, "agent_completed"}
    assert [_one] = heard(clinic, instance)
    Oban.cancel_job(job.id)
  end
end
