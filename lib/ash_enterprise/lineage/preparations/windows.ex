defmodule AshEnterprise.Lineage.Preparations.Windows do
  @moduledoc "Supplies `AshEnterprise.Lineage.Window`'s fixed rows to the simple data layer."

  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _opts, _context),
    do: Ash.DataLayer.Simple.set_data(query, AshEnterprise.Lineage.Window.all())
end
