defmodule AshEnterprise.Mdm.Calculations.ExplanationText do
  @moduledoc """
  A match candidate's per-rule explanation as text, one rule per line, for
  the steward's detail: `email_exact: 1 (weight 1.0)` from the matcher's
  `%{rule => %{"c" => contribution, "w" => weight}}`, or `email_exact: 1.0`
  from a `%{"rules" => [...]}` list. Reads only the candidate's own
  `explanation`.
  """

  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:explanation]

  @impl true
  def calculate(records, _opts, _context) do
    {:ok, Enum.map(records, &text(&1.explanation))}
  end

  defp text(%{"rules" => [_ | _] = rules}), do: Enum.map_join(rules, "\n", &rule/1)

  # The matcher's own shape: rule name => contribution (`c`) and weight (`w`).
  defp text(%{} = explanation) when map_size(explanation) > 0 do
    explanation
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map_join("\n", fn
      {name, %{"c" => contribution, "w" => weight}} ->
        "#{name}: #{contribution} (weight #{weight})"

      {name, other} ->
        "#{name}: #{inspect(other)}"
    end)
  end

  defp text(_explanation), do: nil

  defp rule(%{"rule" => name, "score" => score}), do: "#{name}: #{score}"
  defp rule(rule) when is_binary(rule), do: rule
  defp rule(rule), do: inspect(rule)
end
