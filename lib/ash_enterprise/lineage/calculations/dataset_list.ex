defmodule AshEnterprise.Lineage.Calculations.DatasetList do
  @moduledoc """
  A job run's datasets as one line of text, `namespace/name` comma-separated:
  how the Lineage app's tables show what a run read and wrote.
  """

  use Ash.Resource.Calculation

  @impl true
  def init(opts) do
    if opts[:field] in [:inputs, :outputs],
      do: {:ok, opts},
      else: {:error, "field must be :inputs or :outputs"}
  end

  @impl true
  def load(_query, opts, _context), do: [opts[:field]]

  @impl true
  def calculate(records, opts, _context) do
    Enum.map(records, fn record ->
      record
      |> Map.get(opts[:field])
      |> List.wrap()
      |> Enum.map_join(", ", &AshEnterprise.Lineage.Graph.dataset_label/1)
    end)
  end
end
