defmodule Battery.Execution.Step do
  @moduledoc "The battery's run journal: the `AshAgent.Step` fragment on a plain resource."

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer,
    fragments: [AshAgent.Step]

  postgres do
    table "battery_agent_steps"
    repo Battery.Repo
  end
end
