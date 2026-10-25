defmodule Battery.Bpmn.DecisionResolver do
  @moduledoc """
  The REAL routing seam (scenario 2): an `AshBpmn.DecisionResolver` backed
  by ash_decisions. A `businessRuleTask`'s decision reference is a
  `battery_<name>` DMN definition key; this resolver loads the latest
  PUBLISHED definition for the key, evaluates it through
  `AshDecisions.Evaluator` (which records the evaluation), and hands the
  engine the engine-shaped result: the decision's OUTPUTS, the definition
  VERSION that answered, and the engine's MATCHED RULE IDS.

  Everything crossing the seam is data: `ref` (the definition key), the
  FEEL inputs, and the returned outputs/version/rule_ids. The graph never
  carries the rule table; the decision never learns about the process.
  """

  @behaviour AshBpmn.DecisionResolver

  @impl true
  def decide(ref, inputs, _context) do
    with {:ok, definition} <- latest_published(ref),
         {:ok, result} <-
           AshDecisions.Evaluator.evaluate(definition, inputs,
             evaluation_resource: Battery.Decisions.Evaluation
           ) do
      # A single-output table answers with the scalar; the engine-shaped
      # result always exposes an OUTPUTS MAP for promotion.
      outputs =
        case result.outputs do
          %{} = map -> map
          scalar -> %{"value" => scalar}
        end

      {:ok,
       %{
         outputs: outputs,
         version: result.definition_version,
         rule_ids: result.matched_rule_ids
       }}
    end
  end

  @impl true
  def exists?(ref) do
    match?({:ok, _}, latest_published(ref))
  end

  defp latest_published(key) do
    list =
      case Battery.Decisions.Definition.latest_published(key) do
        list when is_list(list) -> list
        {:ok, list} when is_list(list) -> list
        {:ok, nil} -> []
        {:ok, record} when is_map(record) -> [record]
        {:error, reason} -> {:error, reason}
        _ -> []
      end

    case list do
      [latest | _] -> {:ok, latest}
      [] -> {:error, {:no_such_decision, key}}
      {:error, reason} -> {:error, reason}
    end
  end
end
