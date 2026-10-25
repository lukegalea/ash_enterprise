defmodule Battery.Fixtures do
  @moduledoc """
  The battery's fixture documents: a calibration band table (DMN), a risk
  tier decision (DMN) and the risk-review process (BPMN). These are DATA —
  DMN XML is the single artifact, never generated from code at runtime;
  they live here as verbatim documents the tests publish.
  """

  # The band table for the case-review family: `admit` at p_supports >= 0.8,
  # `review` below. Two rules, UNIQUE hit policy, string `band` output, no
  # default rule — a malformed score matches no row and the empty match is a
  # refusal (ADR 0041). The decision name carries the family tag
  # (`bands_case_review`) — the key a calibration gate keys off.
  @band_table_dmn """
  <?xml version="1.0" encoding="UTF-8"?>
  <definitions xmlns="https://www.omg.org/spec/DMN/20230324/MODEL/"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
               id="bands_case_review_definitions"
               name="bands_case_review"
               namespace="https://battery.test/bands_case_review"
               expressionLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/"
               typeLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/">
    <inputData id="input_p_supports" name="evidence_support__p_supports">
      <variable id="var_p_supports" name="evidence_support__p_supports" typeRef="number"/>
    </inputData>
    <decision id="decision_bands_case_review" name="bands_case_review">
      <variable id="var_bands_case_review" name="bands_case_review" typeRef="string"/>
      <informationRequirement id="req_p_supports">
        <requiredInput href="#input_p_supports"/>
      </informationRequirement>
      <decisionTable id="table_bands_case_review" hitPolicy="UNIQUE" outputLabel="band">
        <input id="clause_p_supports" label="Support probability">
          <inputExpression id="expr_p_supports" typeRef="number">
            <text>evidence_support__p_supports</text>
          </inputExpression>
        </input>
        <output id="clause_band" name="band" label="band" typeRef="string"/>
        <rule id="rule_admit">
          <inputEntry id="rule_admit_0"><text>&gt;= 0.8</text></inputEntry>
          <outputEntry id="rule_admit_1"><text>"admit"</text></outputEntry>
        </rule>
        <rule id="rule_review">
          <inputEntry id="rule_review_0"><text>&lt; 0.8</text></inputEntry>
          <outputEntry id="rule_review_1"><text>"review"</text></outputEntry>
        </rule>
      </decisionTable>
    </decision>
  </definitions>
  """

  # The risk tier decision: `high` at amount >= 1000, `low` below. UNIQUE,
  # no default rule — an absent amount matches no row and refuses.
  @risk_tier_dmn """
  <?xml version="1.0" encoding="UTF-8"?>
  <definitions xmlns="https://www.omg.org/spec/DMN/20230324/MODEL/"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
               id="battery_risk_tier_definitions"
               name="battery_risk_tier"
               namespace="https://battery.test/battery_risk_tier"
               expressionLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/"
               typeLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/">
    <inputData id="input_amount" name="amount">
      <variable id="var_amount" name="amount" typeRef="number"/>
    </inputData>
    <decision id="decision_battery_risk_tier" name="battery_risk_tier">
      <variable id="var_battery_risk_tier" name="battery_risk_tier" typeRef="string"/>
      <informationRequirement id="req_amount">
        <requiredInput href="#input_amount"/>
      </informationRequirement>
      <decisionTable id="table_battery_risk_tier" hitPolicy="UNIQUE" outputLabel="tier">
        <input id="clause_amount" label="Order amount">
          <inputExpression id="expr_amount" typeRef="number">
            <text>amount</text>
          </inputExpression>
        </input>
        <output id="clause_tier" name="tier" label="tier" typeRef="string"/>
        <rule id="rule_high">
          <inputEntry id="rule_high_0"><text>&gt;= 1000</text></inputEntry>
          <outputEntry id="rule_high_1"><text>"high"</text></outputEntry>
        </rule>
        <rule id="rule_low">
          <inputEntry id="rule_low_0"><text>&lt; 1000</text></inputEntry>
          <outputEntry id="rule_low_1"><text>"low"</text></outputEntry>
        </rule>
      </decisionTable>
    </decision>
  </definitions>
  """

  # The risk-review process: start → businessRuleTask (decision ref
  # `battery_risk_tier`, FEEL input `amount` read off the subject, ONE
  # declared scalar signal `tier` promoted onto the token) → exclusive
  # gateway reading `routing.tier` → service task on the high branch,
  # default to the low branch, distinct end outcomes.
  @risk_tier_process """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                     xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                     xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                     id="Definitions_battery_risk">
    <bpmn2:process id="Process_battery_risk" isExecutable="true">
      <bpmn2:startEvent id="Start">
        <bpmn2:outgoing>F_start</bpmn2:outgoing>
      </bpmn2:startEvent>

      <bpmn2:businessRuleTask id="AssessRisk" name="Assess risk">
        <bpmn2:extensionElements>
          <ash:decision ref="battery_risk_tier" binding="latest"/>
          <ash:inputs>
            <ash:input name="amount" from="subject.amount"/>
          </ash:inputs>
          <ash:promote>
            <ash:signal name="tier" from="value" required="true"/>
          </ash:promote>
        </bpmn2:extensionElements>
        <bpmn2:incoming>F_start</bpmn2:incoming>
        <bpmn2:outgoing>F_assessed</bpmn2:outgoing>
      </bpmn2:businessRuleTask>

      <bpmn2:exclusiveGateway id="Route" default="F_low">
        <bpmn2:incoming>F_assessed</bpmn2:incoming>
        <bpmn2:outgoing>F_high</bpmn2:outgoing>
        <bpmn2:outgoing>F_low</bpmn2:outgoing>
      </bpmn2:exclusiveGateway>

      <bpmn2:serviceTask id="Escalate">
        <bpmn2:extensionElements>
          <ash:taskConfig action="escalate"/>
        </bpmn2:extensionElements>
        <bpmn2:incoming>F_high</bpmn2:incoming>
        <bpmn2:outgoing>F_escalated</bpmn2:outgoing>
      </bpmn2:serviceTask>

      <bpmn2:serviceTask id="AutoApprove">
        <bpmn2:extensionElements>
          <ash:taskConfig action="auto_approve"/>
        </bpmn2:extensionElements>
        <bpmn2:incoming>F_low</bpmn2:incoming>
        <bpmn2:outgoing>F_approved</bpmn2:outgoing>
      </bpmn2:serviceTask>

      <bpmn2:endEvent id="EndHigh">
        <bpmn2:extensionElements><ash:taskConfig outcome="escalated"/></bpmn2:extensionElements>
        <bpmn2:incoming>F_escalated</bpmn2:incoming>
      </bpmn2:endEvent>
      <bpmn2:endEvent id="EndLow">
        <bpmn2:extensionElements><ash:taskConfig outcome="approved"/></bpmn2:extensionElements>
        <bpmn2:incoming>F_approved</bpmn2:incoming>
      </bpmn2:endEvent>

      <bpmn2:sequenceFlow id="F_start" sourceRef="Start" targetRef="AssessRisk"/>
      <bpmn2:sequenceFlow id="F_assessed" sourceRef="AssessRisk" targetRef="Route"/>
      <bpmn2:sequenceFlow id="F_high" sourceRef="Route" targetRef="Escalate">
        <bpmn2:conditionExpression xsi:type="bpmn2:tFormalExpression"
          language="feel">routing.tier = "high"</bpmn2:conditionExpression>
      </bpmn2:sequenceFlow>
      <bpmn2:sequenceFlow id="F_low" sourceRef="Route" targetRef="AutoApprove"/>
      <bpmn2:sequenceFlow id="F_escalated" sourceRef="Escalate" targetRef="EndHigh"/>
      <bpmn2:sequenceFlow id="F_approved" sourceRef="AutoApprove" targetRef="EndLow"/>
    </bpmn2:process>
  </bpmn2:definitions>
  """

  def band_table_dmn, do: @band_table_dmn
  def risk_tier_dmn, do: @risk_tier_dmn
  def risk_tier_process, do: @risk_tier_process
end
