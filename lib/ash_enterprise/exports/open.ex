defmodule AshEnterprise.Exports.Open do
  @moduledoc """
  `AshEnterprise.Exports.Export.open`: the resource a type names, or nil. Runs only
  after the export privilege's policy passed, and reads nothing.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Exports.Csv

  @impl true
  def run(input, _opts, _context), do: {:ok, Csv.resource_for(input.arguments.type)}
end
