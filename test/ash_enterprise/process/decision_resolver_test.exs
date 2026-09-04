defmodule AshEnterprise.Process.DecisionResolverTest do
  @moduledoc """
  The one thing this resolver adds to a plain evaluation call: forwarding the decision name a
  diagram names, and staying out of the way otherwise.

  A document with one decision and no name works, which is the common case; a document with
  several and no name is an *error* rather than a guess — that is the evaluator's contract,
  and the resolver must neither break it nor paper over it.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Decisions
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Process.{DecisionResolver, Resolver}

  @two_decisions """
  <?xml version="1.0" encoding="UTF-8"?>
  <definitions xmlns="https://www.omg.org/spec/DMN/20230324/MODEL/"
               xmlns:dmndi="https://www.omg.org/spec/DMN/20230324/DMNDI/"
               xmlns:dc="http://www.omg.org/spec/DMN/20180521/DC/"
               xmlns:di="http://www.omg.org/spec/DMN/20180521/DI/"
               id="resolver_two_definitions"
               name="Two decisions"
               namespace="https://ash-enterprise.example/dmn/resolver-two"
               expressionLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/"
               typeLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/">
    <inputData id="input_tier" name="tier">
      <variable id="var_tier" name="tier" typeRef="string"/>
    </inputData>

    <decision id="decision_first" name="First">
      <variable id="var_first" name="First" typeRef="string"/>
      <informationRequirement id="req_first">
        <requiredInput href="#input_tier"/>
      </informationRequirement>
      <decisionTable id="table_first" hitPolicy="UNIQUE">
        <input id="clause_first">
          <inputExpression id="expr_first" typeRef="string">
            <text>tier</text>
          </inputExpression>
        </input>
        <output id="out_first" name="First" typeRef="string"/>
        <rule id="rule_first">
          <inputEntry id="ie_first"><text>"standard"</text></inputEntry>
          <outputEntry id="oe_first"><text>"one"</text></outputEntry>
        </rule>
      </decisionTable>
    </decision>

    <decision id="decision_second" name="Second">
      <variable id="var_second" name="Second" typeRef="string"/>
      <informationRequirement id="req_second">
        <requiredInput href="#input_tier"/>
      </informationRequirement>
      <decisionTable id="table_second" hitPolicy="UNIQUE">
        <input id="clause_second">
          <inputExpression id="expr_second" typeRef="string">
            <text>tier</text>
          </inputExpression>
        </input>
        <output id="out_second" name="Second" typeRef="string"/>
        <rule id="rule_second">
          <inputEntry id="ie_second"><text>"standard"</text></inputEntry>
          <outputEntry id="oe_second"><text>"two"</text></outputEntry>
        </rule>
      </decisionTable>
    </decision>

    <dmndi:DMNDI>
      <dmndi:DMNDiagram id="diagram_two">
        <dmndi:DMNShape id="shape_first" dmnElementRef="decision_first">
          <dc:Bounds height="80" width="180" x="160" y="80"/>
        </dmndi:DMNShape>
        <dmndi:DMNShape id="shape_second" dmnElementRef="decision_second">
          <dc:Bounds height="80" width="180" x="420" y="80"/>
        </dmndi:DMNShape>
        <dmndi:DMNShape id="shape_input_tier" dmnElementRef="input_tier">
          <dc:Bounds height="60" width="180" x="290" y="280"/>
        </dmndi:DMNShape>
        <dmndi:DMNEdge id="edge_req_first" dmnElementRef="req_first">
          <di:waypoint x="290" y="280"/>
          <di:waypoint x="250" y="160"/>
        </dmndi:DMNEdge>
        <dmndi:DMNEdge id="edge_req_second" dmnElementRef="req_second">
          <di:waypoint x="380" y="280"/>
          <di:waypoint x="510" y="160"/>
        </dmndi:DMNEdge>
      </dmndi:DMNDiagram>
    </dmndi:DMNDI>
  </definitions>
  """

  setup do
    platform = Seeder.seed_platform_organization()

    %{organization: organization} =
      Seeder.seed_tenant(
        unique_name: "resolver-#{System.unique_integer([:positive])}",
        email: "resolver-#{System.unique_integer([:positive])}@example.com"
      )

    on_exit(&Resolver.forget_platform_tenant/0)

    %{platform: platform.id, tenant: organization.id}
  end

  defp opts(tenant), do: [actor: SystemActor.process(), tenant: tenant]

  # `org` is the tenant to publish *into*: the platform organization for the baseline flows
  # `decide/3` falls through to, any tenant for `exists?/1`, which reads across tenants.
  defp publish!(key, xml, org) do
    definition = Decisions.Definition.create!(%{key: key, name: key, xml: xml}, opts(org))

    assert definition.errors in [nil, []], "#{key} did not compile: #{inspect(definition.errors)}"

    Decisions.Definition.publish!(definition, opts(org))
  end

  describe "decide/3" do
    test "a named decision is the one evaluated", %{platform: platform, tenant: tenant} do
      publish!("resolver.two", @two_decisions, platform)

      assert {:ok, result} =
               DecisionResolver.decide(
                 "resolver.two",
                 %{"tier" => "standard"},
                 %{tenant: tenant, decision_name: "Second"}
               )

      # The Second decision answered, not the document's first: that is the forwarding
      # observable. The resolver's result carries only the promoted outputs and the version.
      assert result.outputs == %{"Second" => "two"}
      assert result.version == 1
    end

    test "a nil decision name is forwarded as nothing at all", %{
      platform: platform,
      tenant: tenant
    } do
      # The single-decision document a process usually binds to: the name is optional and the
      # resolver must not turn "absent" into an empty string or a stray option.
      publish!("resolver.risk", File.read!("priv/dmn/access_request_risk.dmn"), platform)

      assert {:ok, result} =
               DecisionResolver.decide(
                 "resolver.risk",
                 %{"requestedRoleTier" => "standard", "justificationLength" => 50},
                 %{tenant: tenant, decision_name: nil}
               )

      assert result.outputs == %{"RiskTier" => "low"}
    end

    test "several decisions and no name is an error, not a guess", %{
      platform: platform,
      tenant: tenant
    } do
      publish!("resolver.two", @two_decisions, platform)

      assert {:error, _reason} =
               DecisionResolver.decide(
                 "resolver.two",
                 %{"tier" => "standard"},
                 %{tenant: tenant}
               )
    end
  end

  describe "exists?/1" do
    test "a published decision anywhere by this key", %{tenant: tenant} do
      refute DecisionResolver.exists?("resolver.anywhere")

      publish!("resolver.anywhere", File.read!("priv/dmn/access_request_risk.dmn"), tenant)
      assert DecisionResolver.exists?("resolver.anywhere")

      # ...but a draft alone is not one: the check answers "could a node execute against
      # this?", and only a published version can.
      draft =
        Decisions.Definition.create!(
          %{key: "resolver.draft_only", name: "draft only", xml: @two_decisions},
          opts(tenant)
        )

      assert draft.errors in [nil, []]
      refute DecisionResolver.exists?("resolver.draft_only")

      Decisions.Definition.publish!(draft, opts(tenant))
      assert DecisionResolver.exists?("resolver.draft_only")
    end
  end
end
