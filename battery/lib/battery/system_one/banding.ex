defmodule Battery.SystemOne.Banding do
  @moduledoc """
  The battery's banding ledger: the `AshJudgments.Banding.Fragment` on the
  battery's own base — the recorded (never recomputed) band decision, whose
  `band_table` identity is the ash_decisions definition the band came from.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events],
    fragments: [AshJudgments.Banding.Fragment]

  events do
    event_log(Battery.Events.EventLog)
    create_timestamp :banded_at
  end

  postgres do
    table "battery_bandings"
    repo(Battery.Repo)
  end
end
