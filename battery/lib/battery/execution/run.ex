defmodule Battery.Execution.Run do
  @moduledoc """
  The battery's agent runs: the `AshAgent.Run` fragment on a plain resource. No
  triggers: the battery takes each step itself (`AshAgent.Run.Stepper.step/3`), as a
  host's `:step` job would, so a run that waits is nothing but its rows.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer,
    fragments: [AshAgent.Run]

  postgres do
    table "battery_agent_runs"
    repo Battery.Repo
  end

  run do
    agent_version(Battery.Execution.AgentVersion)
    step(Battery.Execution.Step)
    invocation(Battery.Execution.Invocation)
    runtime(Battery.Execution.Runtime)
  end
end
