defmodule AshEnterprise.Test.Paper do
  @moduledoc """
  Test-only domain for the synthetic document kinds the generic paper tests
  issue (`AshEnterprise.Test.Paper.ActivitySummary`): their rows live in
  `AshEnterprise.Test.Paper.Entry`, on ETS. Compiled only in `:test` and never
  registered in `config :ash_enterprise, ash_domains`, so it cannot reach a
  running application or a migration.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshEnterprise.Test.Paper.Entry
  end
end
