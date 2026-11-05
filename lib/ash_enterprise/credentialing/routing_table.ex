defmodule AshEnterprise.Credentialing.RoutingTable do
  @moduledoc """
  The clinic's review routing table (showcase slice 4, F10): a one-rule DMN decision,
  `"credentialing.review_route"`, that says who reviews a credential of a given tier. Its
  first version sends a standard credential to the committee; the version the tour's
  "change the routing table" control publishes sends it to the director.

  It is published into the tenant that uses it, as the case process is
  (`AshEnterprise.Credentialing.CaseProcess`), and bound to the tenant until a release pins
  it (`AshEnterprise.Credentialing.ReleaseDemoData`). A case started under a release keeps
  the version that release pinned, whatever the table says later (ADR 0058,
  `AshEnterprise.Process.DecisionResolver`).
  """

  require Ash.Query

  alias AshEnterprise.Decisions.Definition
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Process.{Binding, DecisionResolver}

  @key "credentialing.review_route"
  @routes ["committee", "director"]

  @doc "The decision's key."
  @spec key() :: String.t()
  def key, do: @key

  @doc "The routes the table's versions send a standard credential to, in version order."
  @spec routes() :: [String.t()]
  def routes, do: @routes

  @doc """
  Publishes the table's next version into `tenant` and binds the tenant to it, until a
  release pins one: version 1 sends a standard credential to the first route, each later
  version to the next. `{:published, version}`, or `:unchanged` once every route is in.
  """
  @spec publish_next!(Ash.UUID.t()) :: {:published, pos_integer()} | :unchanged
  def publish_next!(tenant) do
    opts = [actor: SystemActor.process(), tenant: tenant]
    published = published(tenant)

    case Enum.at(@routes, length(published)) do
      nil ->
        :unchanged

      route ->
        definition = Definition.create!(%{key: @key, name: @key, xml: xml(route)}, opts)
        true = definition.errors in [nil, []]
        definition = Definition.publish!(definition, opts)
        bind_if_unbound!(definition, tenant)
        {:published, definition.version}
    end
  end

  # A release looks for the newest definition the tenant owns, which it does once the tenant
  # is bound to its own copy of the key.
  defp bind_if_unbound!(definition, tenant) do
    opts = [actor: SystemActor.process(), tenant: tenant]

    case Binding.by_key(:decision, @key, Keyword.put(opts, :not_found_error?, false)) do
      {:ok, %Binding{}} ->
        :ok

      _unbound ->
        Binding.bind!(
          %{
            kind: :decision,
            key: @key,
            source: :tenant,
            target_id: definition.id,
            bound_version: definition.version
          },
          opts
        )
    end
  end

  defp published(tenant) do
    Definition
    |> Ash.Query.filter(key == ^@key and status == :published)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
  end

  @doc """
  Routes a standard credential: `{route, table version}`, evaluated as `instance` would
  evaluate it, so a case that started under a release gets the version that release pinned.
  """
  @spec route(Ash.UUID.t(), map() | nil) :: {:ok, {String.t(), pos_integer()}} | {:error, term()}
  def route(tenant, instance) do
    with {:ok, result} <-
           DecisionResolver.decide(@key, %{"tier" => "standard"}, %{
             tenant: tenant,
             instance: instance
           }) do
      {:ok, {result.outputs["Route"], result.version}}
    end
  end

  # One rule: a `tier` input and the route it answers with.
  defp xml(route) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <definitions xmlns="https://www.omg.org/spec/DMN/20230324/MODEL/"
                 xmlns:dmndi="https://www.omg.org/spec/DMN/20230324/DMNDI/"
                 xmlns:dc="http://www.omg.org/spec/DMN/20180521/DC/"
                 xmlns:di="http://www.omg.org/spec/DMN/20180521/DI/"
                 id="review_route" name="Review route"
                 namespace="https://ash-enterprise.example/dmn/review-route"
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
end
