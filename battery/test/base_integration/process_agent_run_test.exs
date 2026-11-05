defmodule Battery.Integration.ProcessAgentRunTest do
  @moduledoc """
  Scenario 9 — process ↔ agent run: a process hands work to an agent and waits for it.

  A service task starts a run (`Battery.Execution.ProcessRun`), as the member who started
  the instance and keyed by the engine's invocation key, and promotes its `run_id`. A
  receive task waits for the run's CloudEvents envelope (`Battery.Execution.RunFinished`),
  correlated on that id; the run's final transition writes the envelope in its own
  transaction. A second service task reads how the run ended, from the run, and an
  exclusive gateway routes on it.

  Asserted: the key and owner of the run the engine's execution of the node starts, and
  that a redelivery of the node finds that run and starts none; the process waits, with
  the token parked and listening for this run's id; the envelope carries the CloudEvents
  attributes, names the run and the epoch, and nothing the run said; the engine's
  correlator, handed the envelope as a host's event sweep hands it, wakes the process once;
  the same envelope handed over again, or an envelope for another run, moves nothing; and
  a cancelled run's envelope takes the other branch of the gateway.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias AshAgent.Run.Stepper
  alias AshBpmn.Triggers.Correlator
  alias Battery.Bpmn.{Definition, Instance, Invoker, ProcessEvent, Token}
  alias Battery.Execution.{AgentVersion, Member, Run, RunFinished}
  alias Battery.ScriptedModel

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
            <ash:input name="agent" from="&quot;battery.intake&quot;"/>
            <ash:input name="input" from="&quot;SYNTHETIC: take the intake for the new referral.&quot;"/>
          </ash:inputs>
          <ash:promote><ash:signal name="run_id" required="true"/></ash:promote>
        </bpmn2:extensionElements>
        <bpmn2:incoming>F1</bpmn2:incoming>
        <bpmn2:outgoing>F2</bpmn2:outgoing>
      </bpmn2:serviceTask>

      <bpmn2:receiveTask id="AwaitRun" name="Wait for the agent">
        <bpmn2:extensionElements>
          <ash:subscribe resource="Battery.Execution.RunFinished" action="emit"
                         correlate="routing.run_id" match="data.subject"/>
        </bpmn2:extensionElements>
        <bpmn2:incoming>F2</bpmn2:incoming>
        <bpmn2:outgoing>F3</bpmn2:outgoing>
      </bpmn2:receiveTask>

      <bpmn2:serviceTask id="ReadOutcome" name="Read how it ended">
        <bpmn2:extensionElements>
          <ash:taskConfig action="agent_run_outcome"/>
          <ash:inputs><ash:input name="run_id" from="routing.run_id"/></ash:inputs>
          <ash:promote><ash:signal name="outcome" required="true"/></ash:promote>
        </bpmn2:extensionElements>
        <bpmn2:incoming>F3</bpmn2:incoming>
        <bpmn2:outgoing>F4</bpmn2:outgoing>
      </bpmn2:serviceTask>

      <bpmn2:exclusiveGateway id="Route" default="F_other">
        <bpmn2:incoming>F4</bpmn2:incoming>
        <bpmn2:outgoing>F_done</bpmn2:outgoing>
        <bpmn2:outgoing>F_other</bpmn2:outgoing>
      </bpmn2:exclusiveGateway>

      <bpmn2:endEvent id="Finished">
        <bpmn2:extensionElements><ash:taskConfig outcome="agent_completed"/></bpmn2:extensionElements>
        <bpmn2:incoming>F_done</bpmn2:incoming>
      </bpmn2:endEvent>
      <bpmn2:endEvent id="NotFinished">
        <bpmn2:extensionElements><ash:taskConfig outcome="agent_did_not_complete"/></bpmn2:extensionElements>
        <bpmn2:incoming>F_other</bpmn2:incoming>
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
    </bpmn2:process>
  </bpmn2:definitions>
  """

  # What a host's event source hands the engine for an envelope that reached its log: the
  # published context contract (`AshBpmn.EventSource.context/1`).
  defmodule Events do
    def context(%RunFinished{} = message) do
      %{
        "event" => %{
          "id" => message.id,
          "sequence" => 0,
          "occurred_at" => message.time,
          "resource" => "Battery.Execution.RunFinished",
          "action" => "emit",
          "action_type" => "create",
          "record_id" => message.id,
          "version" => 1
        },
        "actor" => %{},
        "tenant" => %{},
        "data" => %{
          "event_id" => message.event_id,
          "source" => message.source,
          "type" => message.type,
          "subject" => message.subject,
          "data" => message.data
        },
        "changed" => %{},
        "metadata" => %{}
      }
    end
  end

  setup_all do
    Enum.each([Battery.Execution.Identity, Battery.Execution.Runtime], &Code.ensure_loaded!/1)
    :ok
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Battery.Repo, sandbox: false)

    for table <- ~w(battery_run_finished battery_agent_steps battery_invocations
                    battery_agent_runs battery_agent_versions battery_members battery_referrals
                    bpmn_definitions bpmn_instances bpmn_tokens bpmn_process_events) do
      Battery.Repo.query!("DELETE FROM " <> table)
    end

    AshBpmn.Runtime.Oban.TestJobs.clear()
    Invoker.clear_calls()

    AgentVersion
    |> Ash.ActionInput.for_action(:register_from_code, %{agent: Battery.Execution.Intake})
    |> Ash.run_action!()
    |> Ash.Changeset.for_update(:apply_publish, %{})
    |> Ash.update!()

    starter = Ash.create!(Member, %{name: "Dana (nurse)", role: "nurse"})
    %{starter: starter, definition: publish_process!("battery_agent_work", @process)}
  end

  test "the engine starts the run once, as the starter, and the process waits for its envelope",
       ctx do
    instance = start!(ctx.starter)
    [token] = tokens_at(instance, "StartRun")
    [run] = Ash.read!(Run)

    assert run.run_key == "bpmn:#{instance.id}:#{token.id}:StartRun"
    assert {run.origin, run.executing_principal} == {:bpmn, %{type: :person, id: ctx.starter.id}}

    # A redelivery of the node finds that run and starts none.
    assert {:ok, %{"run_id" => run_id}} =
             Invoker.invoke("start_agent_run", %{
               invocation_key: {instance.id, token.id, "StartRun"},
               instance: instance,
               inputs: %{"agent" => "battery.intake", "input" => "SYNTHETIC: again."}
             })

    assert run_id == run.id
    assert [_one] = Ash.read!(Run)

    # The process waits, listening for this run and no other, with no job to wake it.
    assert [%{status: :waiting} = parked] = tokens_at(instance, "AwaitRun")

    assert {parked.correlation_key, parked.subscription_signature} ==
             {run.id, "message:Battery.Execution.RunFinished:emit"}

    assert Ash.get!(Instance, instance.id).status == :running
  end

  test "the run's final transition writes the envelope, and delivering it wakes the process once",
       ctx do
    instance = start!(ctx.starter)
    [run] = Ash.read!(Run)
    assert Ash.read!(RunFinished) == []

    ScriptedModel.script!([{:text, ~s({"ward": "4B"})}])
    assert {:ok, :completed} = step(run)
    assert %{status: :completed, lease_epoch: epoch} = Ash.get!(Run, run.id)

    # A CloudEvents 1.0 envelope, named for the run and the epoch it finished under, that
    # says how the run ended and nothing it said.
    assert [message] = Ash.read!(RunFinished)

    assert %{
             event_id: event_id,
             source: source,
             type: "agent.run.finished",
             subject: subject,
             data: data
           } = message

    assert {event_id, source, subject} ==
             {"#{run.id}:#{epoch}", "/execution/runs/#{run.id}", run.id}

    assert data == %{"status" => "completed"}
    assert Ash.get!(Instance, instance.id).status == :running

    # An envelope for another run wakes nothing.
    deliver!(%{message | subject: Ash.UUID.generate()})
    assert Ash.get!(Instance, instance.id).status == :running

    # This run's wakes the process, which reads how the run ended and routes on it.
    deliver!(message)
    done = Ash.get!(Instance, instance.id)
    assert {done.status, done.outcome} == {:completed, "agent_completed"}
    assert [_one] = heard(instance)

    # The same envelope again, as a sweep replays it, moves nothing.
    deliver!(message)
    assert [_one] = heard(instance)
    assert tokens_at(instance, "Finished") |> length() == 1
    assert [_one] = Ash.read!(Run)

    # And the table refuses the duplicate envelope: consumers dedupe on source and id.
    assert {:error, _duplicate} =
             RunFinished
             |> Ash.Changeset.for_create(
               :emit,
               Map.take(message, [:event_id, :source, :type, :subject, :time, :data])
             )
             |> Ash.create()
  end

  test "a cancelled run's envelope takes the other branch", ctx do
    instance = start!(ctx.starter)
    [run] = Ash.read!(Run)

    run
    |> Ash.Changeset.for_update(:request_cancel, %{})
    |> Ash.update!()

    assert [message] = Ash.read!(RunFinished)
    assert message.data == %{"status" => "cancelled"}

    deliver!(message)
    done = Ash.get!(Instance, instance.id)
    assert {done.status, done.outcome} == {:completed, "agent_did_not_complete"}
  end

  defp step(run), do: Stepper.step(Run, run.id, [])

  defp start!(starter) do
    {:ok, instance} =
      AshBpmn.start_instance(Battery.Domain,
        process: "battery_agent_work",
        subject: Ash.create!(Battery.Execution.Referral, %{patient: "SYNTHETIC patient"}),
        started_by_id: starter.id
      )

    instance
  end

  # What a host's sweep does with an envelope in its log.
  defp deliver!(message) do
    domain = Battery.Domain
    resources = AshBpmn.Runtime.DomainResolver.resolve!(domain)
    scope = %AshBpmn.Scope{AshBpmn.Scope.from_job(%{}, :sweep) | domain: domain}

    ctx = %{
      scope: scope,
      tenant: nil,
      domain: domain,
      resources: resources,
      event_source: Events
    }

    Correlator.dispatch_event(message, [], ctx)
  end

  defp heard(instance) do
    ProcessEvent
    |> Ash.Query.filter(instance_id == ^instance.id and kind == :message_received)
    |> Ash.read!()
  end

  defp tokens_at(instance, node_id) do
    Token
    |> Ash.Query.filter(instance_id == ^instance.id and node_id == ^node_id)
    |> Ash.read!()
  end

  defp publish_process!(key, xml) do
    defn = Definition.create!(%{key: key, name: "Battery #{key}", xml: xml})

    if defn.graph do
      Battery.Repo.query!(
        "UPDATE bpmn_definitions SET status = 'published' WHERE id = '#{defn.id}'"
      )

      Definition.by_key_version!(defn.key, defn.version)
    else
      raise "Definition #{key} failed to compile: #{inspect(defn.errors)}"
    end
  end
end
