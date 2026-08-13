defmodule AshEnterprise.Conformance do
  @moduledoc """
  Test-only domain holding the fixtures the authorization conformance suite runs
  against. Compiled only in `:test` (see `elixirc_paths` in mix.exs) and never
  registered in `config :ash_enterprise, ash_domains`, so it cannot leak into a
  running application or a migration.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshEnterprise.Conformance.Widget
  end
end
