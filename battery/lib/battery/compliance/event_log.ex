defmodule Battery.Compliance.EventLog do
  @moduledoc """
  The battery's compliance event log: the AshEvents log the compliance
  plane watches. The battery's projector is drained synchronously in the
  scenarios (`AshCompliance.Testing.drain_sync/3`); the log exists so the
  projector's wiring names a real host log, the way a production host's
  would.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.EventLog]

  postgres do
    table "battery_compliance_event_log"
    repo Battery.Repo
  end

  event_log do
    primary_key_type Ash.Type.UUIDv7
  end

  actions do
    read :read do
      primary? true
      pagination keyset?: true, required?: false
    end
  end
end
