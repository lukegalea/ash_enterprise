defmodule Battery.Execution.AgentVersion do
  @moduledoc """
  The battery's agent versions: the `AshAgent.AgentVersion` fragment on a plain
  resource. The battery publishes with `apply_publish` directly; a host's governed
  publish path is its own.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer,
    fragments: [AshAgent.AgentVersion]

  postgres do
    table "battery_agent_versions"
    repo Battery.Repo
  end
end
