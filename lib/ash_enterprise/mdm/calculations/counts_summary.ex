defmodule AshEnterprise.Mdm.Calculations.CountsSummary do
  @moduledoc """
  An import batch's running counters (`counts`) as one line, in pipeline
  order: `12 landed · 12 staged · 3 candidates · 2 review`. Counters the
  batch has not reached are left out. Reads only the batch's own `counts`.
  """

  use Ash.Resource.Calculation

  @order ~w(landed staged validation_failed candidates admitted review omitted created merged)

  @impl true
  def load(_query, _opts, _context), do: [:counts]

  @impl true
  def calculate(records, _opts, _context) do
    {:ok, Enum.map(records, &summary(&1.counts))}
  end

  defp summary(counts) when is_map(counts) and map_size(counts) > 0 do
    counts = Map.new(counts, fn {key, value} -> {to_string(key), value} end)

    @order
    |> Enum.filter(&Map.has_key?(counts, &1))
    |> Enum.map_join(" · ", &"#{counts[&1]} #{String.replace(&1, "_", " ")}")
  end

  defp summary(_counts), do: "nothing counted yet"
end
