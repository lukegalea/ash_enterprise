defmodule Battery.BusinessEvents.LedgerClearForReplay do
  @moduledoc """
  The ledger log's `clear_records_for_replay`: clears the battery's ledger
  consumers (never the ledger itself).
  """

  use AshEvents.ClearRecordsForReplay

  @impl true
  def clear_records!(_opts) do
    import Ecto.Query

    Battery.Repo.delete_all(from(s in Battery.BusinessEvents.VendorState))
    :ok
  end
end
