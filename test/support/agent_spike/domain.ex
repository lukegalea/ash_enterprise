defmodule AshEnterprise.AgentSpike do
  @moduledoc """
  Test-only domain for the proof spikes under `test/ash_agent_spike/`.
  Compiled only in `:test` and never registered in
  `config :ash_enterprise, ash_domains`, so it reaches no migration and no
  running application.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshEnterprise.AgentSpike.Subject
  end
end
