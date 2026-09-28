defmodule AshEnterprise.Zones.TestDomain do
  @moduledoc """
  Test-only domain for the zone admission fixtures. Compiled only in `:test` and
  never registered in `config :ash_enterprise, ash_domains`.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshEnterprise.Zones.TestItem
  end
end
