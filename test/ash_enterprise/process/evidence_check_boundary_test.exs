defmodule AshEnterprise.Process.EvidenceCheckBoundaryTest do
  @moduledoc """
  A credential's evidence checks run side by side, each a service task through its
  invocation. One check's business refusal (an `AshAgent.BusinessError`, failure class
  `:business`) is a BPMN error its error boundary catches, while the sibling check
  carries on and completes (F7).

  Both checks rejoin at a parallel join, the refused one through its boundary, and the
  join fires once, after both have arrived. SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  import AshEnterprise.Test.Process.EvidenceChecks

  alias AshEnterprise.Bpmn.ProcessEvent

  @checks """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                     xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                     id="Definitions_credential_checks"
                     targetNamespace="https://github.com/lukegalea/ash_bpmn/ns">
    <bpmn2:error id="Error_NoDocument" name="No licence document" errorCode="licence_document_missing"/>

    <bpmn2:process id="Process_credential_checks" name="Credential evidence checks" isExecutable="true">
      <bpmn2:startEvent id="Start"><bpmn2:outgoing>F_start</bpmn2:outgoing></bpmn2:startEvent>

      <bpmn2:parallelGateway id="Fork">
        <bpmn2:incoming>F_start</bpmn2:incoming>
        <bpmn2:outgoing>F_documents</bpmn2:outgoing>
        <bpmn2:outgoing>F_expiry</bpmn2:outgoing>
      </bpmn2:parallelGateway>

      <bpmn2:serviceTask id="CheckDocuments" name="Check the licence documents">
        <bpmn2:extensionElements><ash:taskConfig action="check_licence_documents"/></bpmn2:extensionElements>
        <bpmn2:incoming>F_documents</bpmn2:incoming>
        <bpmn2:outgoing>F_documented</bpmn2:outgoing>
      </bpmn2:serviceTask>

      <bpmn2:boundaryEvent id="NoDocument" name="No licence document" attachedToRef="CheckDocuments">
        <bpmn2:outgoing>F_missing</bpmn2:outgoing>
        <bpmn2:errorEventDefinition id="ErrDef_NoDocument" errorRef="Error_NoDocument"/>
      </bpmn2:boundaryEvent>

      <bpmn2:serviceTask id="CheckExpiry" name="Check the expiry date">
        <bpmn2:extensionElements><ash:taskConfig action="check_licence_expiry"/></bpmn2:extensionElements>
        <bpmn2:incoming>F_expiry</bpmn2:incoming>
        <bpmn2:outgoing>F_in_date</bpmn2:outgoing>
      </bpmn2:serviceTask>

      <bpmn2:parallelGateway id="Join">
        <bpmn2:incoming>F_documented</bpmn2:incoming>
        <bpmn2:incoming>F_missing</bpmn2:incoming>
        <bpmn2:incoming>F_in_date</bpmn2:incoming>
        <bpmn2:outgoing>F_end</bpmn2:outgoing>
      </bpmn2:parallelGateway>

      <bpmn2:endEvent id="End"><bpmn2:incoming>F_end</bpmn2:incoming></bpmn2:endEvent>

      <bpmn2:sequenceFlow id="F_start" sourceRef="Start" targetRef="Fork"/>
      <bpmn2:sequenceFlow id="F_documents" sourceRef="Fork" targetRef="CheckDocuments"/>
      <bpmn2:sequenceFlow id="F_expiry" sourceRef="Fork" targetRef="CheckExpiry"/>
      <bpmn2:sequenceFlow id="F_documented" sourceRef="CheckDocuments" targetRef="Join"/>
      <bpmn2:sequenceFlow id="F_missing" sourceRef="NoDocument" targetRef="Join"/>
      <bpmn2:sequenceFlow id="F_in_date" sourceRef="CheckExpiry" targetRef="Join"/>
      <bpmn2:sequenceFlow id="F_end" sourceRef="Join" targetRef="End"/>
    </bpmn2:process>
  </bpmn2:definitions>
  """

  @documents "AshEnterprise.Credentialing.Credential.check_documents"
  @expiry "AshEnterprise.Credentialing.Credential.check_expiry"

  setup do
    clinic = clinic!()
    %{clinic: clinic, definition: publish!(clinic, @checks)}
  end

  test "a check refused by a business rule takes its boundary while its sibling completes", %{
    clinic: clinic,
    definition: definition
  } do
    # No licence document is filed: the documents check refuses.
    start!(clinic, definition)

    instance = instance!(clinic, definition)
    assert instance.status == :completed

    by_target = Map.new(invocations(clinic), &{&1.target, &1})

    assert %{status: :failed, failure_class: :business, error_code: "licence_document_missing"} =
             refused = by_target[@documents]

    assert %{status: :succeeded, result: %{"value" => %{"expires_on" => _}}} = by_target[@expiry]

    # The boundary interrupted the check, naming the code and the invocation that refused.
    assert [interrupted] = events(clinic, instance, :activity_interrupted)

    assert {interrupted.node_id, interrupted.data["interrupted"], interrupted.data["error_code"]} ==
             {"NoDocument", "CheckDocuments", "licence_document_missing"}

    assert interrupted.data["details"] =~ refused.id

    assert_joined_once(clinic, instance)
  end

  test "with a document on file both checks complete and no boundary is taken", %{
    clinic: clinic,
    definition: definition
  } do
    file_document!(clinic, :certificate)
    start!(clinic, definition)

    instance = instance!(clinic, definition)
    assert instance.status == :completed
    assert Enum.map(invocations(clinic), & &1.status) == [:succeeded, :succeeded]
    assert events(clinic, instance, :activity_interrupted) == []
    assert_joined_once(clinic, instance)
  end

  defp events(clinic, instance, kind) do
    ProcessEvent
    |> Ash.Query.filter(instance_id == ^instance.id and kind == ^kind)
    |> Ash.read!(tenant: clinic.tenant, authorize?: false)
  end

  # The join fired once, after one arrival from each branch, and one token reached the end.
  defp assert_joined_once(clinic, instance) do
    assert [fired] =
             clinic
             |> events(instance, :node_completed)
             |> Enum.filter(&(&1.node_id == "Join"))

    assert %{"join" => "fired", "arrived_token_ids" => [_, _]} = fired.data
    assert [_] = tokens_at(clinic, instance, "End")
  end
end
