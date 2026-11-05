defmodule Battery.Fixtures do
  @moduledoc """
  The battery's fixture documents: a calibration band table (DMN), a risk
  tier decision (DMN), the risk-review process (BPMN), the intake standing
  decision (DMN) and the scheduled-activation process (BPMN). These are DATA —
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

  # The amount tier decision: `high` at amount >= 1000, `low` below. UNIQUE,
  # no default rule — an absent amount matches no row and refuses.
  @amount_tier_dmn """
  <?xml version="1.0" encoding="UTF-8"?>
  <definitions xmlns="https://www.omg.org/spec/DMN/20230324/MODEL/"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
               id="battery_amount_tier_definitions"
               name="battery_amount_tier"
               namespace="https://battery.test/battery_amount_tier"
               expressionLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/"
               typeLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/">
    <inputData id="input_amount" name="amount">
      <variable id="var_amount" name="amount" typeRef="number"/>
    </inputData>
    <decision id="decision_battery_amount_tier" name="battery_amount_tier">
      <variable id="var_battery_amount_tier" name="battery_amount_tier" typeRef="string"/>
      <informationRequirement id="req_amount">
        <requiredInput href="#input_amount"/>
      </informationRequirement>
      <decisionTable id="table_battery_amount_tier" hitPolicy="UNIQUE" outputLabel="tier">
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
  # `battery_amount_tier`, FEEL input `amount` read off the subject, ONE
  # declared scalar signal `tier` promoted onto the token) → exclusive
  # gateway reading `routing.tier` → service task on the high branch,
  # default to the low branch, distinct end outcomes.
  @amount_tier_process """
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
          <ash:decision ref="battery_amount_tier" binding="latest"/>
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

  # The intake standing decision: the compliance plane's overall outcome for
  # an applicant mapped to a standing. UNIQUE, no default rule — an outcome
  # that is neither `compliant` nor `noncompliant` (unknown, error) matches
  # no row and refuses rather than collapsing to either standing.
  @intake_standing_dmn """
  <?xml version="1.0" encoding="UTF-8"?>
  <definitions xmlns="https://www.omg.org/spec/DMN/20230324/MODEL/"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
               id="battery_intake_standing_definitions"
               name="battery_intake_standing"
               namespace="https://battery.test/battery_intake_standing"
               expressionLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/"
               typeLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/">
    <inputData id="input_intake_outcome" name="intake_outcome">
      <variable id="var_intake_outcome" name="intake_outcome" typeRef="string"/>
    </inputData>
    <decision id="decision_battery_intake_standing" name="battery_intake_standing">
      <variable id="var_battery_intake_standing" name="battery_intake_standing" typeRef="string"/>
      <informationRequirement id="req_intake_outcome">
        <requiredInput href="#input_intake_outcome"/>
      </informationRequirement>
      <decisionTable id="table_battery_intake_standing" hitPolicy="UNIQUE" outputLabel="standing">
        <input id="clause_intake_outcome" label="Intake outcome">
          <inputExpression id="expr_intake_outcome" typeRef="string">
            <text>intake_outcome</text>
          </inputExpression>
        </input>
        <output id="clause_standing" name="standing" label="standing" typeRef="string"/>
        <rule id="rule_proceed">
          <inputEntry id="rule_proceed_0"><text>"compliant"</text></inputEntry>
          <outputEntry id="rule_proceed_1"><text>"proceed"</text></outputEntry>
        </rule>
        <rule id="rule_hold">
          <inputEntry id="rule_hold_0"><text>"noncompliant"</text></inputEntry>
          <outputEntry id="rule_hold_1"><text>"hold"</text></outputEntry>
        </rule>
      </decisionTable>
    </decision>
  </definitions>
  """

  # The scheduled-activation process: start → a timer catch (PT1H, an ISO
  # duration: what ash_bpmn timers take) → service task activating the
  # subject's dated rule-set revision → service task re-evaluating every
  # applicant in the subject's organization → end. The subject carries the
  # revision and its effective instant; the diagram never does.
  @scheduled_activation_process """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                     xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                     xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                     id="Definitions_battery_scheduled_activation">
    <bpmn2:process id="Process_battery_scheduled_activation" isExecutable="true">
      <bpmn2:startEvent id="Start">
        <bpmn2:outgoing>F_start</bpmn2:outgoing>
      </bpmn2:startEvent>

      <bpmn2:intermediateCatchEvent id="Wait" name="Wait for the activation window">
        <bpmn2:incoming>F_start</bpmn2:incoming>
        <bpmn2:outgoing>F_due</bpmn2:outgoing>
        <bpmn2:timerEventDefinition id="Timer_wait">
          <bpmn2:timeDuration xsi:type="bpmn2:tFormalExpression">PT1H</bpmn2:timeDuration>
        </bpmn2:timerEventDefinition>
      </bpmn2:intermediateCatchEvent>

      <bpmn2:serviceTask id="Activate" name="Activate the dated revision">
        <bpmn2:extensionElements>
          <ash:taskConfig action="activate_scheduled_revision"/>
        </bpmn2:extensionElements>
        <bpmn2:incoming>F_due</bpmn2:incoming>
        <bpmn2:outgoing>F_activated</bpmn2:outgoing>
      </bpmn2:serviceTask>

      <bpmn2:serviceTask id="Reevaluate" name="Re-evaluate the scope">
        <bpmn2:extensionElements>
          <ash:taskConfig action="reevaluate_scope"/>
        </bpmn2:extensionElements>
        <bpmn2:incoming>F_activated</bpmn2:incoming>
        <bpmn2:outgoing>F_reevaluated</bpmn2:outgoing>
      </bpmn2:serviceTask>

      <bpmn2:endEvent id="End">
        <bpmn2:extensionElements><ash:taskConfig outcome="activated"/></bpmn2:extensionElements>
        <bpmn2:incoming>F_reevaluated</bpmn2:incoming>
      </bpmn2:endEvent>

      <bpmn2:sequenceFlow id="F_start" sourceRef="Start" targetRef="Wait"/>
      <bpmn2:sequenceFlow id="F_due" sourceRef="Wait" targetRef="Activate"/>
      <bpmn2:sequenceFlow id="F_activated" sourceRef="Activate" targetRef="Reevaluate"/>
      <bpmn2:sequenceFlow id="F_reevaluated" sourceRef="Reevaluate" targetRef="End"/>
    </bpmn2:process>
  </bpmn2:definitions>
  """

  def band_table_dmn, do: @band_table_dmn
  def amount_tier_dmn, do: @amount_tier_dmn
  def amount_tier_process, do: @amount_tier_process
  def intake_standing_dmn, do: @intake_standing_dmn
  def scheduled_activation_process, do: @scheduled_activation_process
end
