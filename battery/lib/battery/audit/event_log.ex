defmodule Battery.Audit.EventLog do
  @moduledoc """
  A hash-chained audit log, one chain per organization (`ash_events_chain`'s
  `{:chained_log, ...}`), with its archive (`Battery.Audit.ArchivedEvent`) and run ledger
  (`Battery.Audit.ArchiveRun`). The ledger is the one the evidence archive's moves are
  recorded in too.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.EventLog, AshEvents.Chain.Extension]

  use AshEvents.Chain.Resources,
      {:chained_log,
       partition: :organization_id,
       partition_metadata_key: "organization_id",
       archive_table: "battery_audit_event_archive",
       archive_run: Battery.Audit.ArchiveRun}

  postgres do
    table "battery_audit_events"
    repo Battery.Repo
  end

  event_log do
    primary_key_type Ash.Type.UUIDv7
    advisory_lock_key_generator AshEvents.Chain.LockKeyGenerator
  end

  actions do
    defaults [:read]
  end

  multitenancy do
    strategy :attribute
    attribute :organization_id
    global? true
  end
end
