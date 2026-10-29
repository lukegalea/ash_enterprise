defmodule Battery.SystemOne.Judgment do
  @moduledoc """
  The battery's judgment ledger: the `AshJudgments.Ledger.Fragment` on the
  battery's own base (Postgres + AshEvents audit) — the observation record
  the evidence-backed judge writes into.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events],
    fragments: [AshJudgments.Ledger.Fragment]

  postgres do
    table "battery_judgments"
    repo Battery.Repo
  end

  events do
    event_log Battery.Events.EventLog
    create_timestamp :recorded_at
  end
end
