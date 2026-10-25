defmodule Battery.Events.EventLog do
  @moduledoc """
  The AshEvents event log for the battery: every judgment-side write
  (observations, materialised facts, bandings) lands here, so the audit
  the ledger fragments assume is real. Same shape as the reference hosts
  build (ash_judgments' test support app).
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.EventLog]

  event_log do
    primary_key_type(Ash.Type.UUIDv7)
  end

  actions do
    read :read do
      # Replay streams the log — keyset pagination required.
      primary?(true)
      pagination(keyset?: true, required?: false)
    end
  end

  postgres do
    table "battery_event_log"
    repo(Battery.Repo)
  end
end
