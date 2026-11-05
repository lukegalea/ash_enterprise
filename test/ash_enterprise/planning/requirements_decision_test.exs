defmodule AshEnterprise.Planning.RequirementsDecisionTest do
  @moduledoc """
  The builder's decision key is the one `mix ash_enterprise.bpmn.publish` gives the shipped
  `priv/dmn/canonical_planning_requirements.dmn` (the LAST underscore becomes the dot), and
  the shipped decision evaluates under it. No database.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.Planning.SnapshotBuilder

  @file_name "canonical_planning_requirements"

  # The publish task's filename -> key rule, restated: last underscore becomes the dot.
  defp published_key(name) do
    parts = String.split(name, "_")
    Enum.join(Enum.drop(parts, -1), "_") <> "." <> List.last(parts)
  end

  test "the builder's key is the key the shipped file is published under" do
    assert published_key(@file_name) == "canonical_planning.requirements"
    assert SnapshotBuilder.decision_key() == published_key(@file_name)
  end

  test "the shipped decision evaluates per weekday under that key" do
    xml = File.read!(Path.join(:code.priv_dir(:ash_enterprise), "dmn/#{@file_name}.dmn"))

    definition = %{
      key: SnapshotBuilder.decision_key(),
      version: 1,
      xml: xml,
      graph: AshDecisions.Compiler.compile!(xml)
    }

    for weekday <- AshEnterprise.Planning.Lowering.weekdays() do
      assert {:ok, %{outputs: outputs, definition_key: key}} =
               AshDecisions.Evaluator.evaluate(definition, %{"weekday" => weekday}, record: false)

      assert key == "canonical_planning.requirements"
      assert is_map(outputs)
    end

    # A name that is not a weekday matches no rule: no outputs, which the lowerer refuses.
    assert {:ok, %{outputs: nil}} =
             AshDecisions.Evaluator.evaluate(definition, %{"weekday" => "funday"}, record: false)
  end
end
