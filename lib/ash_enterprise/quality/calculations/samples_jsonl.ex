defmodule AshEnterprise.Quality.Calculations.SamplesJsonl do
  @moduledoc "A suite's cases as Inspect `Sample` JSONL (`AshEnterprise.Quality.Interchange.Samples`)."

  use Ash.Resource.Calculation

  alias AshEnterprise.Quality.Interchange.Samples

  @impl true
  def load(_query, _opts, _context), do: [:cases]

  @impl true
  def calculate(suites, _opts, _context), do: Enum.map(suites, &Samples.export(&1.cases))
end
