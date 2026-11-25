defmodule AshEnterprise.Test.Paper.ClauseTables do
  @moduledoc """
  Test support: publishes a `paper.clause.*` decision table into a tenant with
  no maker-checker, the way the paper tests need one in place. A tenant's own
  tables go through the decision designer (draft, verify, publish by a second
  person); this shortcut lives in test support only, so nothing a running
  application reaches can publish without that review.

  `xml("hazard_note")` is the table of the SYNTHETIC
  `AshEnterprise.Test.Paper.ActivitySummary` kind: one decision, UNIQUE hit,
  one boolean output `include`, categorical inputs from the payload's typed
  facts (`AshEnterprise.Documents.Paper.decision_inputs/2`). The membership
  column's input expression is the FEEL test itself,
  `list contains(categories, "Hazard")`, so the rule cells are the literals
  `true` and `false` over a boolean column. The test sits in the expression,
  not in a cell, because the unary-test layer splits a cell on its commas. And
  `list contains` rather than `"Hazard" in categories`: over an empty list
  the latter answers null, which matches no rule, where `list contains`
  answers `false`, which matches the exclusion.
  `AshEnterprise.Documents.Paper.ClauseTableVerifier` is the publish gate for
  the family, and this path passes it too.
  """

  require Ash.Query

  alias AshEnterprise.Decisions.Definition
  alias AshEnterprise.Documents.Paper
  alias AshEnterprise.Platform.SystemActor

  @doc """
  Publishes `xml` (default: this module's table for `clause_key`) as the
  `paper.clause.<clause_key>` table in `tenant` and binds the tenant to it (an
  upsert on `(kind, key)`, so publishing a new version moves what the tenant
  resolves), returning the published definition. Idempotent: when the latest
  published version already is that table, it is returned and the binding is
  left alone.
  """
  @spec publish!(Ash.UUID.t(), String.t(), String.t() | nil) :: Definition.t()
  def publish!(tenant, clause_key, xml \\ nil) do
    xml = xml || xml(clause_key)
    latest = latest_published(tenant, clause_key)

    cond do
      is_nil(latest) ->
        publish_version!(tenant, clause_key, xml)

      same_xml?(latest, xml) ->
        latest

      true ->
        publish_version!(tenant, clause_key, xml)
    end
  end

  defp latest_published(tenant, clause_key) do
    Definition
    |> Ash.Query.filter(key == ^Paper.decision_key(clause_key) and status == :published)
    |> Ash.Query.sort(version: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(tenant: tenant, authorize?: false)
  end

  defp publish_version!(tenant, clause_key, xml) do
    opts = [actor: SystemActor.process(), tenant: tenant]

    definition =
      Definition
      |> Ash.Changeset.for_create(
        :create,
        %{key: Paper.decision_key(clause_key), name: clause_key, xml: xml},
        opts
      )
      |> Ash.create!(opts)

    if definition.errors not in [nil, []] do
      raise "paper.clause.#{clause_key} did not compile: #{inspect(definition.errors)}"
    end

    # The same gate a person's publish passes: what this version would change
    # in the tenant's issued documents, measured and stored before it publishes
    # (`AshEnterprise.Documents.Paper.ClauseTableVerifier`).
    definition = AshEnterprise.Decisions.measure_definition_impact!(definition, opts)

    published = Definition.publish!(definition, opts)

    # What the tenant resolves, moved onto what was just published: a table
    # published into a tenant is the table that tenant runs (`AshEnterprise.
    # Process.Binding` upserts one row per `(kind, key)`).
    AshEnterprise.Process.Binding.bind!(
      %{
        kind: :decision,
        key: Paper.decision_key(clause_key),
        source: :tenant,
        target_id: published.id,
        bound_version: published.version
      },
      opts
    )

    published
  end

  defp same_xml?(%Definition{} = definition, xml),
    do: String.trim(definition.xml) == String.trim(xml)

  @doc "The synthetic DMN document for clause `key`."
  @spec xml(String.t()) :: String.t()
  def xml("hazard_note") do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <definitions xmlns="https://www.omg.org/spec/DMN/20230324/MODEL/"
                 xmlns:dmndi="https://www.omg.org/spec/DMN/20230324/DMNDI/"
                 xmlns:dc="http://www.omg.org/spec/DMN/20180521/DC/"
                 xmlns:di="http://www.omg.org/spec/DMN/20180521/DI/"
                 id="hazard_note" name="Hazard note"
                 namespace="https://ash-enterprise.example/dmn/paper-clause-hazard-note"
                 expressionLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/"
                 typeLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/">
      <inputData id="input_year" name="year">
        <variable id="var_year" name="year"/>
      </inputData>
      <inputData id="input_categories" name="categories">
        <variable id="var_categories" name="categories"/>
      </inputData>
      <decision id="decision_hazard_note" name="hazard_note">
        <variable id="var_decision" name="include" typeRef="boolean"/>
        <informationRequirement id="req_year">
          <requiredInput href="#input_year"/>
        </informationRequirement>
        <informationRequirement id="req_categories">
          <requiredInput href="#input_categories"/>
        </informationRequirement>
        <decisionTable id="table_hazard_note" hitPolicy="UNIQUE">
          <input id="clause_year">
            <inputExpression id="expr_year"><text>year</text></inputExpression>
          </input>
          <input id="clause_hazard">
            <inputExpression id="expr_hazard" typeRef="boolean"><text>list contains(categories, "Hazard")</text></inputExpression>
          </input>
          <output id="out_include" name="include" typeRef="boolean"/>
          <rule id="rule_hazard_expenses">
            <description>Hazard entries this year: the hazard note explains the follow-up.</description>
            <inputEntry id="ie_hazard_year"><text>-</text></inputEntry>
            <inputEntry id="ie_hazard"><text>true</text></inputEntry>
            <outputEntry id="oe_hazard"><text>true</text></outputEntry>
          </rule>
          <rule id="rule_no_hazard_expenses">
            <description>No Hazard category in this year's totals: the hazard note stays out.</description>
            <inputEntry id="ie_none_year"><text>-</text></inputEntry>
            <inputEntry id="ie_none"><text>false</text></inputEntry>
            <outputEntry id="oe_none"><text>false</text></outputEntry>
          </rule>
        </decisionTable>
      </decision>
      <dmndi:DMNDI>
        <dmndi:DMNDiagram id="diagram_hazard_note">
          <dmndi:DMNShape id="shape_decision" dmnElementRef="decision_hazard_note">
            <dc:Bounds height="80" width="180" x="160" y="80"/>
          </dmndi:DMNShape>
          <dmndi:DMNShape id="shape_year" dmnElementRef="input_year">
            <dc:Bounds height="60" width="180" x="160" y="280"/>
          </dmndi:DMNShape>
          <dmndi:DMNShape id="shape_categories" dmnElementRef="input_categories">
            <dc:Bounds height="60" width="180" x="380" y="280"/>
          </dmndi:DMNShape>
          <dmndi:DMNEdge id="edge_year" dmnElementRef="req_year">
            <di:waypoint x="250" y="280"/>
            <di:waypoint x="250" y="160"/>
          </dmndi:DMNEdge>
          <dmndi:DMNEdge id="edge_categories" dmnElementRef="req_categories">
            <di:waypoint x="470" y="280"/>
            <di:waypoint x="290" y="160"/>
          </dmndi:DMNEdge>
        </dmndi:DMNDiagram>
      </dmndi:DMNDI>
    </definitions>
    """
  end
end
