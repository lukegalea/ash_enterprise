defmodule AshEnterprise.Mdm.Calculations.RuleSummary do
  @moduledoc """
  A mapping's field rules as text, one per line, in rule order:
  `Email → email (trim)`. Reads only the mapping's own `field_rules`.
  """

  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:field_rules]

  @impl true
  def calculate(records, _opts, _context) do
    {:ok, Enum.map(records, &summary(&1.field_rules))}
  end

  defp summary([_ | _] = rules), do: Enum.map_join(rules, "\n", &rule/1)
  defp summary(_rules), do: nil

  defp rule(%{"path" => path, "target" => target} = rule),
    do: "#{path} → #{target} (#{rule["op"] || "identity"})"

  defp rule(rule), do: inspect(rule)
end
