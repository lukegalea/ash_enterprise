defmodule AshEnterprise.Releases.PinningTest do
  @moduledoc """
  Version pinning (ADR 0058, F10; invariant 4): a case keeps the decision version of the
  release it started under.

  A clinic releases a triage process and the decision it routes on. A decision version is
  published and released while an instance on the first release exists: that instance still
  evaluates the version its release pinned, and an instance that starts after the second
  release evaluates the new one. Promotion writes the bindings that say so for a case that
  starts, and rolling back writes the earlier ones again.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.Execution.Runs, only: [clinic!: 0, pause_queues!: 0]

  alias AshEnterprise.Bpmn.Definition, as: ProcessDefinition
  alias AshEnterprise.Decisions.Definition, as: DecisionDefinition
  alias AshEnterprise.Execution
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Process.{Binding, DecisionResolver, Resolver}
  alias AshEnterprise.Test.Execution.Releases

  @process "clinic.triage_flow"
  @decision "clinic.triage_route"

  @process_xml """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                     xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
    <bpmn2:process id="P" isExecutable="true">
      <bpmn2:startEvent id="S"><bpmn2:outgoing>F</bpmn2:outgoing></bpmn2:startEvent>
      <bpmn2:endEvent id="E"><bpmn2:incoming>F</bpmn2:incoming></bpmn2:endEvent>
      <bpmn2:sequenceFlow id="F" sourceRef="S" targetRef="E"/>
    </bpmn2:process>
  </bpmn2:definitions>
  """

  # A one-decision table: a `tier` input and the route its one rule answers with.
  defp dmn(route) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <definitions xmlns="https://www.omg.org/spec/DMN/20230324/MODEL/"
                 xmlns:dmndi="https://www.omg.org/spec/DMN/20230324/DMNDI/"
                 xmlns:dc="http://www.omg.org/spec/DMN/20180521/DC/"
                 xmlns:di="http://www.omg.org/spec/DMN/20180521/DI/"
                 id="triage_route" name="Triage route"
                 namespace="https://ash-enterprise.example/dmn/triage-route"
                 expressionLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/"
                 typeLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/">
      <inputData id="input_tier" name="tier">
        <variable id="var_tier" name="tier" typeRef="string"/>
      </inputData>
      <decision id="decision_route" name="Route">
        <variable id="var_route" name="Route" typeRef="string"/>
        <informationRequirement id="req_route">
          <requiredInput href="#input_tier"/>
        </informationRequirement>
        <decisionTable id="table_route" hitPolicy="UNIQUE">
          <input id="clause_route">
            <inputExpression id="expr_route" typeRef="string"><text>tier</text></inputExpression>
          </input>
          <output id="out_route" name="Route" typeRef="string"/>
          <rule id="rule_route">
            <inputEntry id="ie_route"><text>"standard"</text></inputEntry>
            <outputEntry id="oe_route"><text>"#{route}"</text></outputEntry>
          </rule>
        </decisionTable>
      </decision>
      <dmndi:DMNDI>
        <dmndi:DMNDiagram id="diagram_route">
          <dmndi:DMNShape id="shape_route" dmnElementRef="decision_route">
            <dc:Bounds height="80" width="180" x="160" y="80"/>
          </dmndi:DMNShape>
          <dmndi:DMNShape id="shape_tier" dmnElementRef="input_tier">
            <dc:Bounds height="60" width="180" x="160" y="280"/>
          </dmndi:DMNShape>
          <dmndi:DMNEdge id="edge_route" dmnElementRef="req_route">
            <di:waypoint x="250" y="280"/>
            <di:waypoint x="250" y="160"/>
          </dmndi:DMNEdge>
        </dmndi:DMNDiagram>
      </dmndi:DMNDI>
    </definitions>
    """
  end

  # The baselines live in the platform organization, as the platform ships them; the clinic
  # follows them until a release binds it to a version.
  setup do
    pause_queues!()
    on_exit(&Resolver.forget_platform_tenant/0)
    platform = Seeder.seed_platform_organization()
    Resolver.forget_platform_tenant()
    %{clinic: clinic!(), platform: platform.id}
  end

  defp opts(clinic), do: [actor: SystemActor.process(), tenant: clinic.tenant]
  defp platform_opts(platform), do: [actor: SystemActor.process(), tenant: platform]

  defp publish_decision!(platform, route) do
    definition =
      DecisionDefinition.create!(
        %{key: @decision, name: @decision, xml: dmn(route)},
        platform_opts(platform)
      )

    assert definition.errors in [nil, []], "did not compile: #{inspect(definition.errors)}"
    DecisionDefinition.publish!(definition, platform_opts(platform))
  end

  defp publish_process!(platform) do
    definition =
      ProcessDefinition.create!(
        %{key: @process, name: @process, xml: @process_xml},
        platform_opts(platform)
      )

    AshEnterprise.Repo.query!(
      "UPDATE bpmn_definitions SET status = 'published' WHERE id = $1",
      [Ecto.UUID.dump!(definition.id)]
    )

    definition
  end

  defp release!(clinic),
    do:
      Releases.release!(clinic, "clinic.triage", [
        %{kind: "process", key: @process},
        %{kind: "decision", key: @decision}
      ])

  # As the host starts one: the definition the tenant runs, resolved by the host.
  defp start!(clinic) do
    {:ok, definition} = Resolver.resolve(:process, @process, clinic.tenant)

    AshBpmn.start_instance!(AshEnterprise.Bpmn,
      definition: definition,
      process: @process,
      subject_type: "ClinicCase",
      subject_id: Ash.UUID.generate(),
      actor: clinic.admin.actor,
      tenant: clinic.tenant
    )
  end

  defp decide(instance, clinic) do
    {:ok, result} =
      DecisionResolver.decide(@decision, %{"tier" => "standard"}, %{
        tenant: clinic.tenant,
        instance: instance
      })

    {result.outputs["Route"], result.version}
  end

  test "an instance keeps the decision version of the release it started under (F10)",
       %{clinic: clinic, platform: platform} do
    one_decision = publish_decision!(platform, "routine")
    publish_process!(platform)

    one = release!(clinic)
    old = start!(clinic)
    assert old.release_manifest_id == one.id

    # Version 2 is published and released while the first instance exists.
    two_decision = publish_decision!(platform, "urgent")
    assert two_decision.version == 2
    two = release!(clinic)
    assert two.status == :active

    assert Execution.get_release_manifest!(one.id, authorize?: false, tenant: clinic.tenant).status ==
             :superseded

    new = start!(clinic)
    assert new.release_manifest_id == two.id

    assert decide(old, clinic) == {"routine", 1}
    assert decide(new, clinic) == {"urgent", 2}

    # With no instance, the decision follows what the tenant is bound to now.
    assert decide(nil, clinic) == {"urgent", 2}
    assert one_decision.id != two_decision.id
  end

  test "promoting binds each process and decision entry, and rolling back binds the earlier ones",
       %{clinic: clinic, platform: platform} do
    first = publish_decision!(platform, "routine")
    process = publish_process!(platform)

    one = release!(clinic)

    assert %Binding{source: :platform, target_id: target, bound_version: 1} =
             Binding.by_key!(:decision, @decision, opts(clinic))

    assert target == first.id
    assert Binding.by_key!(:process, @process, opts(clinic)).target_id == process.id

    second = publish_decision!(platform, "urgent")
    two = release!(clinic)
    assert Binding.by_key!(:decision, @decision, opts(clinic)).target_id == second.id

    Execution.rollback_release!(
      Execution.get_release_manifest!(one.id, authorize?: false, tenant: clinic.tenant),
      %{},
      actor: clinic.admin.actor,
      tenant: clinic.tenant
    )

    assert Binding.by_key!(:decision, @decision, opts(clinic)).target_id == first.id
    assert two.id != one.id
  end

  test "an instance of a process no release pins, and a decision no release pins, are not pinned",
       %{clinic: clinic, platform: platform} do
    publish_decision!(platform, "routine")
    publish_process!(platform)

    instance = start!(clinic)
    assert instance.release_manifest_id == nil
    assert decide(instance, clinic) == {"routine", 1}
  end
end
