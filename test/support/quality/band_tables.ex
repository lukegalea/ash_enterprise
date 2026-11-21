defmodule AshEnterprise.Test.Quality.BandTables do
  @moduledoc """
  The `agent_reply_style` family's band table, published as the platform baseline the
  resolver finds, and certifications of it recorded the way a person records one: in
  the certifier's own tenant, not the tenant whose replies are reported. The table is a
  stand-in; nothing bands through it here.
  """

  import AshEnterprise.SystemOne.Support, only: [person: 1]

  alias AshEnterprise.Decisions.Definition
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Process.Resolver
  alias AshEnterprise.SystemOne.BandTableCertification

  @key "judgments_band_agent_reply_style"

  @dmn """
  <?xml version="1.0" encoding="UTF-8"?>
  <definitions xmlns="https://www.omg.org/spec/DMN/20230324/MODEL/"
               id="band_agent_reply_style_definitions"
               name="Agent reply style band"
               namespace="https://ash-enterprise.example/dmn/band-agent-reply-style"
               expressionLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/"
               typeLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/">
    <inputData id="input_value" name="hs1_lead_with_outcome_or_ask__value">
      <variable id="var_value" name="hs1_lead_with_outcome_or_ask__value" typeRef="string"/>
    </inputData>
    <decision id="decision_band" name="Band">
      <variable id="var_band" name="Band" typeRef="string"/>
      <informationRequirement id="req_value">
        <requiredInput href="#input_value"/>
      </informationRequirement>
      <decisionTable id="table_band" hitPolicy="UNIQUE">
        <input id="clause_value">
          <inputExpression id="expr_value" typeRef="string"><text>hs1_lead_with_outcome_or_ask__value</text></inputExpression>
        </input>
        <output id="out_band" name="band" typeRef="string"/>
        <rule id="rule_review"><inputEntry id="ie_review"><text>-</text></inputEntry><outputEntry id="oe_review"><text>"review"</text></outputEntry></rule>
      </decisionTable>
    </decision>
  </definitions>
  """

  @doc "Publishes the family's band table in the platform organization; returns the definition."
  def published! do
    platform = Seeder.seed_platform_organization()
    Resolver.forget_platform_tenant()
    opts = [actor: SystemActor.process(), tenant: platform.id]

    %{key: @key, name: @key, xml: @dmn}
    |> Definition.create!(opts)
    |> Definition.publish!(opts)
  end

  @doc """
  Records a certification of `definition` as a person in a tenant of their own, and
  returns it. `overrides` replace the recorded fields (`definition_version`,
  `content_hash`, `status`).
  """
  def certify!(definition, overrides \\ %{}) do
    tenant = Ash.UUID.generate()
    certifier = person(tenant: tenant)

    BandTableCertification
    |> Ash.Changeset.for_create(
      :record,
      Map.merge(
        %{
          definition_key: definition.key,
          definition_version: to_string(definition.version),
          content_hash: definition.content_hash,
          family: "agent_reply_style",
          verification: %{"optimise_split_disjoint" => true},
          certified_by: to_string(certifier.email)
        },
        overrides
      ),
      actor: certifier,
      tenant: tenant
    )
    |> Ash.create!()
  end
end
