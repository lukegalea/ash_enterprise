defmodule AshEnterprise.Process.RetryInstanceTest do
  @moduledoc """
  `AshBpmn.retry_instance/2` is the operator's remedy once somebody has changed what a
  failed service task's answer depends on. A governed task asks for its answer under the
  engine's invocation key, which a retry keeps; the host must not answer the operator's
  retry with the failure the earlier attempt recorded.

  SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.Process.EvidenceChecks

  alias AshBpmn.Runtime.AdvanceWorker

  @check_documents """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                     xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                     id="Definitions_retry_documents"
                     targetNamespace="https://github.com/lukegalea/ash_bpmn/ns">
    <bpmn2:process id="Process_retry_documents" name="Check the documents" isExecutable="true">
      <bpmn2:startEvent id="Start"><bpmn2:outgoing>F1</bpmn2:outgoing></bpmn2:startEvent>
      <bpmn2:serviceTask id="CheckDocuments" name="Check the licence documents">
        <bpmn2:extensionElements>
          <ash:taskConfig action="check_licence_documents"/>
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
    clinic = clinic!()
    %{clinic: clinic, definition: publish!(clinic, @check_documents)}
  end

  test "an operator's retry asks again once what the answer depends on has changed", %{
    clinic: clinic,
    definition: definition
  } do
    # No document is filed: the check refuses, and the instance fails.
    start!(clinic, definition)
    instance = instance!(clinic, definition)
    assert instance.status == :failed
    assert [%{status: :failed, error_code: "licence_document_missing"}] = invocations(clinic)

    file_document!(clinic, :certificate)

    assert {:ok, _} = AshBpmn.retry_instance(instance, tenant: clinic.tenant, authorize?: false)

    assert instance!(clinic, definition).status == :completed

    # The refusal stays on record; the retry is its own invocation under its own key.
    assert [refused, answered] = invocations(clinic)
    assert {refused.status, answered.status} == {:failed, :succeeded}
    assert refused.invocation_key != answered.invocation_key
  end

  test "an Oban retry of the same attempt still gets the recorded answer", %{
    clinic: clinic,
    definition: definition
  } do
    start!(clinic, definition)
    instance = instance!(clinic, definition)
    [token] = tokens_at(clinic, instance, "CheckDocuments")

    file_document!(clinic, :certificate)

    # A redelivery of the failing attempt (the budget is kept: attempt 2) is not a retry.
    AdvanceWorker.perform(retry_job(clinic, instance, token, 2))
    assert [%{status: :failed}] = invocations(clinic)
  end
end
