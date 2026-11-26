defmodule AshEnterprise.Documents.Paper.Calculations.ImpactSummary do
  @moduledoc """
  One line saying where a candidate's impact report stands
  (`AshEnterprise.Documents.Paper.Impact.summary/2`): not measured, errored,
  stale, or its counts per outcome and whether the cap cut the sample. Read
  from the stored report; nothing is measured on read.
  """

  use Ash.Resource.Calculation

  alias AshEnterprise.Documents.Paper.Impact

  @impl true
  def load(_query, _opts, _context), do: [:impact_report, :content_hash]

  @impl true
  def calculate(records, _opts, _context),
    do: Enum.map(records, &Impact.summary(&1.impact_report, &1.content_hash))
end
