defmodule AshEnterprise.Process.InvocationKeyTest do
  @moduledoc """
  A service task that names a declared target runs it through its invocation
  (`AshEnterprise.Process.ServiceInvocation`), keyed by the engine's invocation key.

    * A redelivery of the advance job, after the first delivery ran the check and died
      before the engine recorded the advance, asks again under the same key, runs
      nothing, and moves the token on with the answer the first delivery recorded.
    * The invocation runs as the person who started the instance, never the process
      actor; a starter who is no longer active stops the task before anything is asked.
    * A target that needs an approval, or reaches outside, is refused at publish.

  Inline mode has no Oban between the engine and the node, so the redelivery drives
  `AshBpmn.Runtime.AdvanceWorker.perform/1` with the attempt a real retry carries.
  SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.Process.EvidenceChecks

  alias AshBpmn.Runtime.AdvanceWorker
  alias AshEnterprise.Faults
  alias AshEnterprise.Process.ServiceInvocation
  alias AshEnterprise.Test.DailyFixtures

  @check_documents """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                     xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                     id="Definitions_check_documents"
                     targetNamespace="https://github.com/lukegalea/ash_bpmn/ns">
    <bpmn2:process id="Process_check_documents" name="Check the documents" isExecutable="true">
      <bpmn2:startEvent id="Start"><bpmn2:outgoing>F1</bpmn2:outgoing></bpmn2:startEvent>
      <bpmn2:serviceTask id="CheckDocuments" name="Check the licence documents">
        <bpmn2:extensionElements>
          <ash:taskConfig action="check_licence_documents"/>
          <ash:promote><ash:signal name="documents_on_file" required="true"/></ash:promote>
        </bpmn2:extensionElements>
        <bpmn2:incoming>F1</bpmn2:incoming>
        <bpmn2:outgoing>F2</bpmn2:outgoing>
      </bpmn2:serviceTask>
      <bpmn2:endEvent id="End"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
      <bpmn2:sequenceFlow id="F1" sourceRef="Start" targetRef="CheckDocuments"/>
      <bpmn2:sequenceFlow id="F2" sourceRef="CheckDocuments" targetRef="End"/>
    </bpmn2:process>
  </bpmn2:definitions>
  """

  setup do
    on_exit(&Faults.disarm_all/0)
    clinic = clinic!()
    file_document!(clinic, :certificate)
    %{clinic: clinic, definition: publish!(clinic, @check_documents)}
  end

  test "an advance-job redelivery runs the check once and returns the recorded result", %{
    clinic: clinic,
    definition: definition
  } do
    # The first delivery runs the check, which records one document on file, and dies
    # before the engine records the advance.
    Faults.arm(:process_invocation_settled, :raise)
    assert_raise RuntimeError, fn -> start!(clinic, definition) end

    instance = instance!(clinic, definition)
    [token] = tokens_at(clinic, instance, "CheckDocuments")

    assert [row] = invocations(clinic)

    assert {row.status, row.invocation_key, row.lease_epoch} ==
             {:succeeded, "bpmn:#{instance.id}:#{token.id}:CheckDocuments", 1}

    assert {row.process_instance_id, row.process_node_id} == {instance.id, "CheckDocuments"}
    assert row.result == %{"value" => %{"documents_on_file" => 1}}

    # A second document is filed before the redelivery: running the check again would
    # now say two.
    file_document!(clinic, :register_extract)

    assert {:ok, :advanced} = AdvanceWorker.perform(retry_job(clinic, instance, token, 2))

    assert [again] = invocations(clinic)
    assert {again.id, again.status, again.lease_epoch} == {row.id, :succeeded, 1}
    assert instance!(clinic, definition).status == :completed

    # The token moved on with the recorded answer.
    assert [%{routing: %{"documents_on_file" => "1"}}] = tokens_at(clinic, instance, "End")
  end

  test "the check runs as the instance's starter", %{clinic: clinic, definition: definition} do
    start!(clinic, definition)

    assert [row] = invocations(clinic)
    person = clinic.admin.user.id
    assert {row.owner_id, row.executing_principal} == {person, %{type: :person, id: person}}
    assert instance!(clinic, definition).status == :completed
  end

  test "a starter who is no longer active stops the task before anything is asked", %{
    clinic: clinic,
    definition: definition
  } do
    left = DailyFixtures.deactivate!(clinic.admin)

    assert_raise RuntimeError, ~r/starter_has_no_authority/, fn ->
      start!(clinic, definition, left.user)
    end

    assert invocations(clinic) == []
  end

  describe "which targets a service task may name" do
    test "a target that needs an approval or reaches outside is refused" do
      assert ServiceInvocation.runnable("AshEnterprise.Credentialing.Credential.check_documents") ==
               :ok

      assert {:error, {:not_a_service_task_target, _, :needs_approval}} =
               ServiceInvocation.runnable(
                 "AshEnterprise.Credentialing.Credential.activate_credential"
               )

      assert {:error, {:not_a_service_task_target, _, :open_world}} =
               ServiceInvocation.runnable(
                 "AshEnterprise.Credentialing.Credential.lookup_activation"
               )

      assert {:error, {:not_a_service_task_target, _, :undeclared}} =
               ServiceInvocation.runnable("AshEnterprise.Credentialing.Credential.read")
    end
  end
end
