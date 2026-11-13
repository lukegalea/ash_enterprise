defmodule Battery.Audit.ArchiveRun do
  @moduledoc """
  The run ledger (`ash_events_chain`'s `{:archive_run, ...}`): one row per retention step,
  for the audit log's moves and the evidence archive's alike. `store` says which.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer

  use AshEvents.Chain.Resources,
      {:archive_run,
       log: Battery.Audit.EventLog,
       table: "battery_audit_archive_runs",
       repo: Battery.Repo,
       chain_attribute: :chain_organization_id}
end
