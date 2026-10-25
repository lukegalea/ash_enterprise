defmodule Battery.SystemOne.Fact do
  @moduledoc """
  The battery's materialised-facts table: the TEMPORAL
  `AshJudgments.Facts.TemporalFragment` on the battery's own base — the
  fact a banding materialises lands here, with admission provenance.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events],
    fragments: [AshJudgments.Facts.TemporalFragment]

  events do
    event_log(Battery.Events.EventLog)
    create_timestamp :recorded_at
  end

  postgres do
    table "battery_facts"
    repo(Battery.Repo)
  end
end
