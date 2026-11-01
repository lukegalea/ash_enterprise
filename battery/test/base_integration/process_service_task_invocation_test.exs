defmodule Battery.Integration.ProcessServiceTaskInvocationTest do
  @moduledoc """
  Scenario 8 — process service task ↔ governed invocation.

  A service task that names a declared `ash_agent` target runs it through its
  invocation (`Battery.Execution.ProcessTask`), keyed by the engine's invocation key
  `{instance, token, node}` written out as `bpmn:<instance>:<token>:<node>`, as the
  member who started the instance.

  Asserted: the key and parent the engine's execution of the node gives the row; the
  governed `acknowledge` runs only through that row and as the starter; a redelivery of
  the node (the same engine key) gets the row back and runs nothing; and a business
  refusal (`AshAgent.BusinessError`) in one parallel branch is the BPMN error its
  boundary catches, while the sibling branch completes.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias AshBpmn.Runtime.Oban.TestJobs
  alias Battery.Bpmn.{Definition, Invoker, ProcessEvent, Token}
  alias Battery.Execution.{Invocation, Member, Referral}

  @acknowledge "Battery.Execution.Referral.acknowledge"
  @check_consent "Battery.Execution.Referral.check_consent"

  @intake """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                     xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                     id="Definitions_referral_intake"
                     targetNamespace="https://github.com/lukegalea/ash_bpmn/ns">
    <bpmn2:error id="Error_NoConsent" name="No consent" errorCode="consent_missing"/>

    <bpmn2:process id="Process_referral_intake" name="Referral intake" isExecutable="true">
      <bpmn2:startEvent id="Start"><bpmn2:outgoing>F_start</bpmn2:outgoing></bpmn2:startEvent>

      <bpmn2:parallelGateway id="Fork">
        <bpmn2:incoming>F_start</bpmn2:incoming>
        <bpmn2:outgoing>F_consent</bpmn2:outgoing>
        <bpmn2:outgoing>F_acknowledge</bpmn2:outgoing>
      </bpmn2:parallelGateway>

      <bpmn2:serviceTask id="CheckConsent" name="Check consent">
        <bpmn2:extensionElements><ash:taskConfig action="check_consent"/></bpmn2:extensionElements>
        <bpmn2:incoming>F_consent</bpmn2:incoming>
        <bpmn2:outgoing>F_consented</bpmn2:outgoing>
      </bpmn2:serviceTask>

      <bpmn2:boundaryEvent id="NoConsent" name="No consent" attachedToRef="CheckConsent">
        <bpmn2:outgoing>F_no_consent</bpmn2:outgoing>
        <bpmn2:errorEventDefinition id="ErrDef_NoConsent" errorRef="Error_NoConsent"/>
      </bpmn2:boundaryEvent>

      <bpmn2:serviceTask id="Acknowledge" name="Acknowledge the referral">
        <bpmn2:extensionElements><ash:taskConfig action="acknowledge_referral"/></bpmn2:extensionElements>
        <bpmn2:incoming>F_acknowledge</bpmn2:incoming>
        <bpmn2:outgoing>F_acknowledged</bpmn2:outgoing>
      </bpmn2:serviceTask>

      <bpmn2:endEvent id="End_Consented"><bpmn2:incoming>F_consented</bpmn2:incoming></bpmn2:endEvent>
      <bpmn2:endEvent id="End_NoConsent"><bpmn2:incoming>F_no_consent</bpmn2:incoming></bpmn2:endEvent>
      <bpmn2:endEvent id="End_Acknowledged"><bpmn2:incoming>F_acknowledged</bpmn2:incoming></bpmn2:endEvent>

      <bpmn2:sequenceFlow id="F_start" sourceRef="Start" targetRef="Fork"/>
      <bpmn2:sequenceFlow id="F_consent" sourceRef="Fork" targetRef="CheckConsent"/>
      <bpmn2:sequenceFlow id="F_acknowledge" sourceRef="Fork" targetRef="Acknowledge"/>
      <bpmn2:sequenceFlow id="F_consented" sourceRef="CheckConsent" targetRef="End_Consented"/>
      <bpmn2:sequenceFlow id="F_no_consent" sourceRef="NoConsent" targetRef="End_NoConsent"/>
      <bpmn2:sequenceFlow id="F_acknowledged" sourceRef="Acknowledge" targetRef="End_Acknowledged"/>
    </bpmn2:process>
  </bpmn2:definitions>
  """

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Battery.Repo, sandbox: false)

    for table <- ~w(battery_invocations battery_referrals battery_members
                    bpmn_definitions bpmn_instances bpmn_tokens bpmn_process_events) do
      Battery.Repo.query!("DELETE FROM " <> table)
    end

    TestJobs.clear()
    Invoker.clear_calls()

    on_exit(fn ->
      TestJobs.clear()
      Invoker.clear_calls()
    end)

    starter = Ash.create!(Member, %{name: "Dana (nurse)", role: "nurse"})
    definition = publish_process!("battery_referral_intake", @intake)

    %{starter: starter, definition: definition}
  end

  test "a governed service task runs through its invocation, keyed by the engine, as the starter",
       ctx do
    referral = referral!(consent: true)
    instance = start!(referral, ctx.starter)

    assert Ash.get!(Battery.Bpmn.Instance, instance.id).status == :completed

    [acknowledge] = rows(@acknowledge)
    [token] = tokens_at(instance, "Acknowledge")

    assert acknowledge.invocation_key == "bpmn:#{instance.id}:#{token.id}:Acknowledge"

    assert {acknowledge.process_instance_id, acknowledge.process_node_id} ==
             {instance.id, "Acknowledge"}

    assert {acknowledge.status, acknowledge.lease_epoch} == {:succeeded, 1}
    assert acknowledge.executing_principal == %{type: :person, id: ctx.starter.id}
    assert acknowledge.owner_id == ctx.starter.id

    acknowledged = Ash.get!(Referral, referral.id)
    assert acknowledged.acknowledged_at

    # Outside its invocation the governed action does not run, for the starter either.
    assert {:error, %Ash.Error.Invalid{}} =
             acknowledged
             |> Ash.Changeset.for_update(:acknowledge, %{}, actor: ctx.starter)
             |> Ash.update()

    # A redelivery of the node: the same engine key gets the row back and runs nothing.
    assert {:ok, %{}} =
             Invoker.invoke("acknowledge_referral", %{
               invocation_key: {instance.id, token.id, "Acknowledge"},
               instance: Ash.get!(Battery.Bpmn.Instance, instance.id),
               subject: acknowledged
             })

    assert [again] = rows(@acknowledge)
    assert {again.id, again.status, again.lease_epoch} == {acknowledge.id, :succeeded, 1}
    assert Ash.get!(Referral, referral.id).acknowledged_at == acknowledged.acknowledged_at
  end

  test "a business refusal takes its error boundary while the sibling branch completes", ctx do
    referral = referral!(consent: false)
    instance = start!(referral, ctx.starter)

    assert Ash.get!(Battery.Bpmn.Instance, instance.id).status == :completed

    assert [%{status: :failed, failure_class: :business, error_code: "consent_missing"} = refused] =
             rows(@check_consent)

    assert [%{status: :succeeded}] = rows(@acknowledge)
    assert Ash.get!(Referral, referral.id).acknowledged_at

    assert [interrupted] =
             ProcessEvent
             |> Ash.Query.filter(instance_id == ^instance.id and kind == :activity_interrupted)
             |> Ash.read!()

    assert {interrupted.node_id, interrupted.data["interrupted"], interrupted.data["error_code"]} ==
             {"NoConsent", "CheckConsent", "consent_missing"}

    assert interrupted.data["details"] =~ refused.id

    assert tokens_at(instance, "End_NoConsent") != []
    assert tokens_at(instance, "End_Acknowledged") != []
    assert tokens_at(instance, "End_Consented") == []
  end

  defp referral!(consent: consent?) do
    Referral
    |> Ash.create!(%{patient: "SYNTHETIC patient #{System.unique_integer([:positive])}"})
    |> Ash.Changeset.for_update(:amend, %{consent_on_file?: consent?})
    |> Ash.update!()
  end

  defp start!(referral, starter) do
    {:ok, instance} =
      AshBpmn.start_instance(Battery.Domain,
        process: "battery_referral_intake",
        subject: referral,
        started_by_id: starter.id
      )

    instance
  end

  defp rows(target) do
    Invocation
    |> Ash.Query.filter(target == ^target)
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
