defmodule Battery.BusinessEvents.Ledger do
  @moduledoc """
  The battery's business-event ledger: the `:ledger` resource macro on the
  battery's own base. The macro emits the locked-and-chained ledger AND the
  simulation twin; the host contributes the base and the policies.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.EventLog, AshDiscreteBusinessEvents.Ledger.Extension]

  use AshDiscreteBusinessEvents.Resources,
      {:ledger,
       repo: Battery.Repo,
       table: "ledger_events",
       simulation_table: "ledger_simulation_events",
       domain: Battery.Domain,
       clear_records_for_replay: Battery.BusinessEvents.LedgerClearForReplay}

  policies do
    policy always() do
      authorize_if always()
    end
  end
end
