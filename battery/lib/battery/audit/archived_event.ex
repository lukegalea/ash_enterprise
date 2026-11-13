defmodule Battery.Audit.ArchivedEvent do
  @moduledoc "Where `Battery.Audit.EventLog`'s events go after the hot window."

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer

  use AshEvents.Chain.Resources,
      {:archive,
       log: Battery.Audit.EventLog, table: "battery_audit_event_archive", repo: Battery.Repo}

  multitenancy do
    strategy :attribute
    attribute :organization_id
    global? true
  end
end
